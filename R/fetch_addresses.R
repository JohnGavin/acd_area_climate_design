#' Fetch Vienna address registry from OGD WFS
#'
#' Downloads the `ogdwien:ADRESSENOGD` layer from the Vienna Open Government
#' Data WFS endpoint, caches the raw GeoJSON to `data-raw/`, and returns a
#' data frame with the address columns needed for ACD ↔ address lookup.
#'
#' The full layer has ~50 columns; this function slims it to the 20 columns
#' required for the upload-page join. The function is cache-first: if the cache
#' file already exists for the requested snapshot date it is read from disk
#' without a network call unless `force = TRUE`.
#'
#' @param snapshot_date Character scalar. ISO-8601 date string used as a
#'   cache-file suffix. Defaults to `ADDRESSES_SNAPSHOT_DATE`.
#' @param max_features Integer or `NULL`. When set, limits the WFS response
#'   via the `count` parameter. `NULL` fetches the full layer (~291 k rows).
#' @param force Logical. When `TRUE`, ignore any existing cache file.
#'
#' @return A data frame with columns:
#'   `ACD`, `SCD_NAME_STR`, `SCD_ZUGANG_STR`, `STRABS_ZUGANG_STR`,
#'   `NAME`, `NAME_STR`, `NAME_ONR`, `ON_VON_NUM`, `ON_VON_ALPHA`,
#'   `ON_BIS_NUM`, `ON_BIS_ALPHA`, `PLZ`, `GEB_BEZIRK`, `ZUG_BEZIRK`,
#'   `OBJEKT_ID`, `GEB_OBJEKTID`, `OBJECTID`, `LAGE_ZU_ADR_TXT`,
#'   `lon`, `lat`.
#'   The attribute `snapshot_date` is set on the returned object.
#'
#' @note Geometry is decoded from the WGS84 point coordinates embedded in the
#'   GeoJSON response; the returned data frame carries `lon` / `lat` columns
#'   rather than an sf geometry column, keeping the result lightweight.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Smoke test — first 500 addresses
#' addr <- fetch_addresses(max_features = 500)
#'
#' # Full fetch (runs for several minutes on first call)
#' addr_full <- fetch_addresses()
#' }
fetch_addresses <- function(
    snapshot_date = ADDRESSES_SNAPSHOT_DATE,
    max_features  = NULL,
    force         = FALSE
) {
  cache_path <- file.path(
    "data-raw",
    paste0("addresses_", snapshot_date, ".geojson")
  )

  # ── Column selection: slim the 50+ WFS columns to the 20 we need ─────────────
  .KEEP_COLS <- c(
    "ACD", "SCD_NAME_STR", "SCD_ZUGANG_STR", "STRABS_ZUGANG_STR",
    "NAME", "NAME_STR", "NAME_ONR",
    "ON_VON_NUM", "ON_VON_ALPHA", "ON_BIS_NUM", "ON_BIS_ALPHA",
    "PLZ", "GEB_BEZIRK", "ZUG_BEZIRK",
    "OBJEKT_ID", "GEB_OBJEKTID", "OBJECTID",
    "LAGE_ZU_ADR_TXT"
  )

  if (file.exists(cache_path) && !force) {
    cli::cli_inform("Reading addresses from cache: {.path {cache_path}}")
    result <- sf::st_read(cache_path, quiet = TRUE)
    result <- .slim_addresses(result, .KEEP_COLS)
    attr(result, "snapshot_date") <- snapshot_date
    return(result)
  }

  cli::cli_inform("Fetching addresses from WFS ({WFS_BASE_URL})")

  query_params <- list(
    service      = "WFS",
    version      = "2.0.0",
    request      = "GetFeature",
    typeNames    = LAYER_ADDRESSES,
    srsName      = "EPSG:4326",
    outputFormat = "application/json"
  )
  if (!is.null(max_features)) {
    query_params$count <- as.integer(max_features)
  }

  dir.create(dirname(cache_path), showWarnings = FALSE, recursive = TRUE)

  if (!is.null(max_features)) {
    # ── Single-request path ──────────────────────────────────────────────────────
    resp <- tryCatch(
      httr2::request(WFS_BASE_URL) |>
        httr2::req_url_query(!!!query_params) |>
        httr2::req_error(is_error = \(r) FALSE) |>
        httr2::req_timeout(120L) |>
        httr2::req_perform(),
      error = function(e) {
        cli::cli_abort(
          c(
            "Network error while fetching addresses from WFS.",
            "i" = "URL: {WFS_BASE_URL}",
            "x" = conditionMessage(e)
          )
        )
      }
    )
    if (httr2::resp_is_error(resp)) {
      cli::cli_abort(
        c(
          "WFS request failed with HTTP {httr2::resp_status(resp)}.",
          "i" = "URL: {httr2::resp_url(resp)}"
        )
      )
    }
    writeBin(httr2::resp_body_raw(resp), cache_path)
    cli::cli_inform("Addresses cached at {.path {cache_path}}")
    result <- sf::st_read(cache_path, quiet = TRUE)

  } else {
    # ── Paginated path (full layer) ──────────────────────────────────────────────
    PAGE_SIZE <- 5000L
    start     <- 0L
    chunks    <- list()
    page_num  <- 1L

    repeat {
      paged_params <- c(
        query_params,
        list(startIndex = start, count = PAGE_SIZE)
      )
      cli::cli_inform(
        "Addresses page {page_num}: startIndex = {start}"
      )
      resp <- tryCatch(
        httr2::request(WFS_BASE_URL) |>
          httr2::req_url_query(!!!paged_params) |>
          httr2::req_error(is_error = \(r) FALSE) |>
          httr2::req_timeout(120L) |>
          httr2::req_perform(),
        error = function(e) {
          cli::cli_abort(
            c(
              "Network error fetching addresses page {page_num}.",
              "i" = "startIndex = {start}",
              "x" = conditionMessage(e)
            )
          )
        }
      )
      if (httr2::resp_is_error(resp)) {
        cli::cli_abort(
          c(
            "WFS request failed with HTTP {httr2::resp_status(resp)} on page {page_num}.",
            "i" = "startIndex = {start}"
          )
        )
      }

      tmp_path <- tempfile(fileext = ".geojson")
      writeBin(httr2::resp_body_raw(resp), tmp_path)
      chunk_sf <- tryCatch(
        sf::st_read(tmp_path, quiet = TRUE),
        error = function(e) {
          cli::cli_warn(
            "Could not parse GeoJSON page {page_num}: {conditionMessage(e)}"
          )
          NULL
        }
      )
      unlink(tmp_path)

      if (is.null(chunk_sf) || nrow(chunk_sf) == 0L) {
        cli::cli_inform(
          "Addresses pagination complete: {start} total features in {page_num - 1L} pages."
        )
        break
      }
      chunks[[page_num]] <- chunk_sf
      cli::cli_inform("  -> {nrow(chunk_sf)} features on page {page_num}")

      if (nrow(chunk_sf) < PAGE_SIZE) break
      start    <- start    + PAGE_SIZE
      page_num <- page_num + 1L
    }

    if (length(chunks) == 0L) {
      cli::cli_abort("Addresses WFS returned 0 features across all pages.")
    }

    result <- do.call(rbind, chunks)
    cli::cli_inform(
      "Addresses pagination complete: {nrow(result)} features in {length(chunks)} pages."
    )
    sf::st_write(result, cache_path, driver = "GeoJSON", quiet = TRUE, delete_dsn = TRUE)
    cli::cli_inform("Addresses cached at {.path {cache_path}}")
  }

  result <- .slim_addresses(result, .KEEP_COLS)
  attr(result, "snapshot_date") <- snapshot_date
  result
}

#' Slim an ADRESSENOGD sf to the required columns, adding lon/lat
#'
#' Extracts the WGS84 coordinates from the sf point geometry and drops the
#' geometry column, returning a plain data frame.
#'
#' @param sf_obj An sf point object from `sf::st_read()` of ADRESSENOGD GeoJSON.
#' @param keep_cols Character vector of attribute columns to retain.
#' @return A data frame with `keep_cols` plus `lon` and `lat`.
#' @keywords internal
#' @noRd
.slim_addresses <- function(sf_obj, keep_cols) {
  # Extract coordinates before dropping geometry
  coords <- tryCatch(
    sf::st_coordinates(sf_obj),
    error = function(e) NULL
  )

  # Drop geometry — work with plain data frame
  df <- sf::st_drop_geometry(sf_obj)

  # Retain only the columns that are present (WFS may vary)
  present <- intersect(keep_cols, names(df))
  missing <- setdiff(keep_cols, names(df))
  if (length(missing) > 0L) {
    cli::cli_warn(
      "ADRESSENOGD is missing expected columns: {.val {missing}}"
    )
  }
  df <- df[, present, drop = FALSE]

  # Attach coordinates
  if (!is.null(coords) && nrow(coords) == nrow(df)) {
    df$lon <- coords[, 1L]
    df$lat <- coords[, 2L]
  } else {
    df$lon <- NA_real_
    df$lat <- NA_real_
  }

  df
}
