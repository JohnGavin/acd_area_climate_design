#' Run the upload-page address-matching algorithm in R
#'
#' Mirrors the JS algorithm in `vignettes/articles/upload.qmd` so that test
#' results in R match what the deployed page produces. Used by snapshot
#' regression tests.
#'
#' **Implementation status (v0):**
#' - Step 1: Normalise input (trim, lowercase street, normalise HausNr). DONE.
#' - Step 2: Exact join on (PLZ, street_norm, house_norm). DONE.
#'   - Step 2a: multi-unit (acd_count > 1) flagged as `ambiguous_multi`. DONE.
#' - Step 3: Fuzzy nearest-house fallback for unmatched simple rows. DONE.
#' - Step 4: Composite-street splitter (Strasse contains "/"). DONE.
#' - Step 5: multi-unit ARRAY_AGG (acd_list). DONE.
#' - Step 6: REST API fallback (Fix C). NOT IMPLEMENTED — requires live network.
#'   TODO: implement optional REST fallback in a follow-up PR.
#'
#' @param input_df data.frame with columns PLZ, Strasse, HausNr (and optional
#'   Stiege_RH, ObjektNr). Column names must already be normalised (no trailing
#'   dots or slashes — rename before passing in).
#' @param addresses Either a data.frame (the address table) or a character path
#'   to an ADRESSENOGD parquet file. Defaults to
#'   `system.file("extdata", "addresses_2026-05-02.parquet", package = "acd")`.
#' @param fuzzy_max_distance Integer. Maximum numeric house-number distance for
#'   fuzzy fallback (mirrors JS constant `FUZZY_MAX_DISTANCE = 20`).
#'   Default 20.
#' @return data.frame with original columns plus:
#'   \describe{
#'     \item{match_quality}{One of `"exact"`, `"ambiguous_multi"`,
#'       `"fuzzy_nearest_house"`, `"split_both"`, `"split_partial"`,
#'       `"unmatched"`.}
#'     \item{ACD}{Primary ACD code, or `NA` for unmatched rows.}
#'     \item{acd_list}{Character; comma-separated list of all ACD codes for
#'       multi-unit buildings; same as ACD for single-unit.}
#'     \item{acd_count}{Integer; number of ACD codes at this address.}
#'     \item{house_distance}{Integer; numeric house-number distance from the
#'       nearest registered house (only for `fuzzy_nearest_house`; `NA`
#'       otherwise).}
#'     \item{n_acd_candidates}{Alias for `acd_count` kept for API
#'       compatibility.}
#'   }
#' @export
run_upload_algorithm <- function(
    input_df,
    addresses        = NULL,
    fuzzy_max_distance = 20L
) {
  # ── Input validation ─────────────────────────────────────────────────────
  if (!is.data.frame(input_df)) {
    cli::cli_abort(c(
      "x" = "{.arg input_df} must be a {.cls data.frame}.",
      "i" = "Got {.cls {class(input_df)}}."
    ))
  }
  required_cols <- c("PLZ", "Strasse", "HausNr")
  missing_cols  <- setdiff(required_cols, names(input_df))
  if (length(missing_cols) > 0) {
    cli::cli_abort(c(
      "x" = "{.arg input_df} is missing required column{?s}: {.field {missing_cols}}.",
      "i" = "Columns present: {.field {names(input_df)}}."
    ))
  }

  # ── Resolve address table ─────────────────────────────────────────────────
  if (is.null(addresses)) {
    parquet_path <- system.file(
      "extdata", "addresses_2026-05-02.parquet",
      package = "acd"
    )
    if (!nzchar(parquet_path) || !file.exists(parquet_path)) {
      cli::cli_abort(c(
        "x" = "Default ADRESSENOGD parquet not found in {.pkg acd} package.",
        "i" = "Pass {.arg addresses} explicitly as a path or data.frame."
      ))
    }
    addr_df <- arrow::read_parquet(parquet_path)
  } else if (is.character(addresses) && length(addresses) == 1) {
    if (!file.exists(addresses)) {
      cli::cli_abort(
        "x" = "Parquet file not found: {.path {addresses}}."
      )
    }
    addr_df <- arrow::read_parquet(addresses)
  } else if (is.data.frame(addresses)) {
    addr_df <- addresses
  } else {
    cli::cli_abort(c(
      "x" = "{.arg addresses} must be a data.frame, a path string, or NULL.",
      "i" = "Got {.cls {class(addresses)}}."
    ))
  }

  # ── Step 1: Normalise address table ──────────────────────────────────────
  # Mirrors the SQL in the DuckDB-Wasm view `addr`:
  #   plz_norm   = CAST(PLZ AS VARCHAR)
  #   street_norm = LOWER(TRIM(NAME_STR))
  #   house_norm  = LOWER(TRIM(NAME_ONR))
  #   acd_list   = ARRAY_AGG(ACD ORDER BY ACD)
  #   acd_count  = COUNT(*)
  addr_norm <- addr_df |>
    dplyr::mutate(
      plz_norm    = as.character(PLZ),
      street_norm = tolower(trimws(NAME_STR)),
      house_norm  = tolower(trimws(NAME_ONR))
    ) |>
    dplyr::group_by(plz_norm, street_norm, house_norm) |>
    dplyr::summarise(
      acd_list  = paste(sort(ACD), collapse = ","),
      acd_count = dplyr::n(),
      ACD       = dplyr::first(ACD[order(ACD)]),
      lon       = dplyr::first(lon),
      lat       = dplyr::first(lat),
      .groups   = "drop"
    )

  # ── Step 1: Normalise input rows ─────────────────────────────────────────
  # Mirrors JS splitComposite() for composite streets and normalisation.
  n_orig <- nrow(input_df)

  # Tag each original row with its index
  input_indexed <- input_df
  input_indexed$.orig_idx <- seq_len(n_orig)

  # Composite-street expansion: if Strasse contains "/" split into sub-rows.
  expanded <- .expand_composite(input_indexed)

  # ── Step 2: Exact join ───────────────────────────────────────────────────
  joined <- dplyr::left_join(
    expanded,
    addr_norm,
    by = c("plz_in" = "plz_norm", "street_in" = "street_norm", "house_in" = "house_norm")
  ) |>
    dplyr::mutate(
      match_quality  = dplyr::case_when(
        is.na(ACD)    ~ "unmatched",
        acd_count > 1 ~ "ambiguous_multi",
        TRUE          ~ "exact"
      ),
      house_distance = NA_integer_   # populated by fuzzy fallback
    )

  # ── Step 3: Fuzzy nearest-house fallback ─────────────────────────────────
  # Only for non-composite unmatched rows.
  joined <- .fuzzy_fallback(joined, addr_norm, fuzzy_max_distance)

  # ── Merge back to original rows ──────────────────────────────────────────
  result <- .merge_to_orig(input_df, expanded, joined)
  result
}

# ── Internal helpers ──────────────────────────────────────────────────────────

#' Expand composite streets (containing "/") into sub-rows
#'
#' @noRd
.expand_composite <- function(input_indexed) {
  rows_out <- vector("list", nrow(input_indexed))

  for (i in seq_len(nrow(input_indexed))) {
    row       <- input_indexed[i, , drop = FALSE]
    plz       <- trimws(as.character(row$PLZ))
    street    <- trimws(as.character(row$Strasse))
    house     <- trimws(as.character(row$HausNr))
    orig_idx  <- row$.orig_idx
    is_parz   <- grepl("parz", house, ignore.case = TRUE)

    if (grepl("/", street, fixed = TRUE)) {
      parts <- Filter(nzchar, trimws(strsplit(street, "/", fixed = TRUE)[[1]]))
      sub_rows <- vector("list", length(parts))
      for (j in seq_along(parts)) {
        part         <- parts[[j]]
        trailing_nr  <- .extract_trailing_number(part)
        street_only  <- trimws(sub("\\s*\\d+\\w*$", "", part))
        sub_rows[[j]] <- data.frame(
          .orig_idx       = orig_idx,
          PLZ             = plz,
          Strasse         = street,   # keep original for merge
          HausNr          = house,
          plz_in          = plz,
          street_in       = tolower(street_only),
          house_in        = tolower(if (!is.na(trailing_nr)) trailing_nr else house),
          garden_plot     = TRUE,
          composite_index = j - 1L,
          composite_total = length(parts),
          stringsAsFactors = FALSE
        )
      }
      rows_out[[i]] <- do.call(rbind, sub_rows)
    } else {
      rows_out[[i]] <- data.frame(
        .orig_idx       = orig_idx,
        PLZ             = plz,
        Strasse         = street,
        HausNr          = house,
        plz_in          = plz,
        street_in       = tolower(street),
        house_in        = tolower(house),
        garden_plot     = is_parz,
        composite_index = 0L,
        composite_total = 1L,
        stringsAsFactors = FALSE
      )
    }
  }

  do.call(rbind, rows_out)
}

#' Extract trailing house number from a composite street part
#'
#' @noRd
.extract_trailing_number <- function(s) {
  m <- regmatches(s, regexpr("(\\d+\\w*)$", s, perl = TRUE))
  if (length(m) == 1 && nzchar(m)) m else NA_character_
}

#' Fuzzy nearest-house fallback (Fix A)
#'
#' For unmatched non-composite rows: find the nearest house number on the
#' same (PLZ, street) and upgrade to `fuzzy_nearest_house` if within
#' `fuzzy_max_distance`.
#'
#' @noRd
.fuzzy_fallback <- function(joined, addr_norm, fuzzy_max_distance) {
  unmatched_idx <- which(
    joined$match_quality == "unmatched" & joined$composite_total == 1
  )
  if (length(unmatched_idx) == 0) return(joined)

  # Add a unique row-level key (the position in joined) so we can patch back
  unmatched_rows <- joined[unmatched_idx, ]
  unmatched_rows$.row_key <- unmatched_idx   # position in joined

  # Extract leading integer from a house string (NA if no leading digits)
  leading_int <- function(s) {
    m <- regexpr("^[0-9]+", s)
    ifelse(m > 0, as.integer(regmatches(s, m)), NA_integer_)
  }

  # For each unmatched row, find candidates on the same (plz, street)
  # then pick the nearest by numeric house distance
  street_matches <- dplyr::inner_join(
    unmatched_rows |>
      dplyr::select(.row_key, .orig_idx, plz_in, street_in, house_in) |>
      dplyr::mutate(house_num_in = leading_int(house_in)) |>
      dplyr::filter(!is.na(house_num_in)),
    addr_norm |>
      dplyr::filter(grepl("^[0-9]", house_norm)) |>
      dplyr::mutate(house_num_addr = leading_int(house_norm)) |>
      dplyr::filter(!is.na(house_num_addr)),
    by = c("plz_in" = "plz_norm", "street_in" = "street_norm")
  ) |>
    dplyr::mutate(
      house_distance = abs(house_num_in - house_num_addr)
    ) |>
    dplyr::filter(house_distance <= fuzzy_max_distance) |>
    dplyr::group_by(.row_key) |>
    dplyr::slice_min(house_distance, n = 1, with_ties = FALSE) |>
    dplyr::ungroup()

  if (nrow(street_matches) == 0) return(joined)

  # Patch joined in-place using the exact row positions (.row_key)
  for (k in seq_len(nrow(street_matches))) {
    ji <- street_matches$.row_key[k]
    sm <- street_matches[k, ]
    joined$ACD[ji]            <- sm$ACD
    joined$acd_list[ji]       <- sm$acd_list
    joined$acd_count[ji]      <- sm$acd_count
    joined$lon[ji]            <- sm$lon
    joined$lat[ji]            <- sm$lat
    joined$house_distance[ji] <- as.integer(sm$house_distance)
    joined$match_quality[ji]  <- "fuzzy_nearest_house"
  }

  joined
}

#' Merge expanded results back to original rows
#'
#' Mirrors JS `mergeResults()`.
#'
#' @noRd
.merge_to_orig <- function(input_df, expanded, joined) {
  quality_rank <- c(
    exact                    =  0,
    ambiguous_multi          =  1,
    fuzzy_nearest_house      =  2,
    split_both               =  3,
    split_partial            =  4,
    unmatched                = 99
  )

  result_rows <- vector("list", nrow(input_df))

  for (i in seq_len(nrow(input_df))) {
    parts <- joined[joined$.orig_idx == i, , drop = FALSE]

    if (nrow(parts) == 0) {
      result_rows[[i]] <- .empty_result_row(input_df[i, , drop = FALSE])
      next
    }

    comp_total <- parts$composite_total[1]

    if (comp_total <= 1) {
      # Non-composite: pick best match_quality
      best_rank <- vapply(parts$match_quality, function(q) quality_rank[q] %||% 98L, numeric(1))
      best      <- parts[which.min(best_rank), , drop = FALSE]

      result_rows[[i]] <- cbind(
        input_df[i, , drop = FALSE],
        data.frame(
          match_quality  = best$match_quality,
          ACD            = if (is.na(best$ACD)) NA_character_ else as.character(best$ACD),
          acd_list       = if (is.na(best$acd_list)) NA_character_ else best$acd_list,
          acd_count      = if (is.na(best$acd_count)) NA_integer_ else as.integer(best$acd_count),
          house_distance = if (is.null(best$house_distance) || is.na(best$house_distance)) NA_integer_
                           else as.integer(best$house_distance),
          n_acd_candidates = if (is.na(best$acd_count)) NA_integer_ else as.integer(best$acd_count),
          stringsAsFactors = FALSE
        )
      )
    } else {
      # Composite: check each part
      p0 <- parts[parts$composite_index == 0, , drop = FALSE]
      p1 <- parts[parts$composite_index == 1, , drop = FALSE]
      m0 <- nrow(p0) > 0 && !is.na(p0$ACD[1])
      m1 <- nrow(p1) > 0 && !is.na(p1$ACD[1])

      mq <- if (m0 && m1) "split_both" else if (m0 || m1) "split_partial" else "unmatched"

      primary <- if (m0) p0 else if (m1) p1 else p0

      result_rows[[i]] <- cbind(
        input_df[i, , drop = FALSE],
        data.frame(
          match_quality    = mq,
          ACD              = if (is.na(primary$ACD[1])) NA_character_ else as.character(primary$ACD[1]),
          acd_list         = if (is.na(primary$acd_list[1])) NA_character_ else primary$acd_list[1],
          acd_count        = if (is.na(primary$acd_count[1])) NA_integer_ else as.integer(primary$acd_count[1]),
          house_distance   = NA_integer_,
          n_acd_candidates = if (is.na(primary$acd_count[1])) NA_integer_ else as.integer(primary$acd_count[1]),
          stringsAsFactors = FALSE
        )
      )
    }
  }

  do.call(rbind, result_rows)
}

#' Build an empty result row for unmatched inputs
#' @noRd
.empty_result_row <- function(row) {
  cbind(
    row,
    data.frame(
      match_quality    = "unmatched",
      ACD              = NA_character_,
      acd_list         = NA_character_,
      acd_count        = NA_integer_,
      house_distance   = NA_integer_,
      n_acd_candidates = NA_integer_,
      stringsAsFactors = FALSE
    )
  )
}

#' NULL-coalescing operator
#' @noRd
`%||%` <- function(x, y) if (is.null(x)) y else x
