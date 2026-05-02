#' Validate the deployed gh-pages dashboard for structural health.
#'
#' Fetches every deployed page and verifies: HTTP status, error markers in
#' rendered content, empty Leaflet containers, broken assets, empty tables,
#' and dangling hash links.
#'
#' @param base_url Site root URL (no trailing slash).
#' @param pages Character vector of paths under `base_url` to validate.
#'   Use `""` for the root index page.
#' @return A tibble with one row per page and columns:
#'   `url`, `http_status`, `error_marker_count`, `empty_leaflet_silent`,
#'   `broken_asset_count`, `empty_table_count`, `broken_hash_count`,
#'   `verdict` (PASS / WARN / FAIL).
#' @export
validate_deploy <- function(
  base_url = "https://johngavin.github.io/acd_area_climate_design",
  pages = c(
    "",
    "vignettes/articles/dashboard.html",
    "vignettes/articles/methodology.html"
  )
) {
  urls <- ifelse(
    nchar(pages) == 0L,
    paste0(base_url, "/"),  # trailing slash so url_absolute resolves into the project sub-path
    paste0(base_url, "/", pages)
  )

  cli::cli_h1("Deploy validation")
  cli::cli_inform("Checking {length(urls)} page{?s} on {.url {base_url}}")

  results <- lapply(urls, function(url) {
    cli::cli_h2("Page: {.url {url}}")
    .validate_one(url, base_url)
  })

  out <- do.call(rbind, results)
  tbl <- tibble::as_tibble(out)

  # Write markdown report
  .format_report(tbl, base_url)

  tbl
}

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

#' Fetch a single page and parse as HTML.
#' @noRd
.fetch_page <- function(url) {
  resp <- tryCatch(
    httr2::request(url) |>
      httr2::req_timeout(15) |>
      httr2::req_perform(),
    error = function(e) {
      cli::cli_warn("Network error fetching {.url {url}}: {conditionMessage(e)}")
      NULL
    }
  )
  if (is.null(resp)) return(list(status = NA_integer_, doc = NULL, body = ""))
  status <- httr2::resp_status(resp)
  if (status != 200L) {
    cli::cli_warn("HTTP {status} for {.url {url}}")
    return(list(status = status, doc = NULL, body = ""))
  }
  body <- httr2::resp_body_string(resp)
  doc  <- tryCatch(xml2::read_html(body), error = function(e) NULL)
  list(status = status, doc = doc, body = body)
}

#' Count error marker strings in raw HTML text.
#' @noRd
.check_error_markers <- function(html_text) {
  # Patterns are specific enough not to collide with normal English prose.
  # Removed "Error in" and "not available" — too generic, hit legit text
  # like "duckplyr is not available in this render environment".
  # Kept patterns are tied to specific failure modes:
  #   MISSING EVIDENCE   → placeholder text from missing target
  #   not found in targets → safe_tar_read() fallback message
  #   #> NULL            → knitr leaking a NULL print
  #   Error in `         → R error with backtick (specific shape)
  patterns <- c(
    "MISSING EVIDENCE"          = "MISSING EVIDENCE",
    "not found in targets"      = "not found in targets",
    "Error in `"                = "Error in `",
    "NULL output"               = "#> NULL"
  )
  vapply(patterns, function(p) {
    matches <- gregexpr(p, html_text, fixed = TRUE)[[1L]]
    # gregexpr returns -1 (length 1) when no match — check first element
    if (length(matches) == 1L && matches[[1L]] == -1L) 0L else length(matches)
  }, integer(1L))
}

#' HEAD-probe all linked CSS and JS assets, return status tibble.
#' Relative paths are resolved against the PAGE URL, not the site root —
#' a path like `../../site_libs/...` resolved against the site root would
#' escape the site entirely.
#' @noRd
.check_assets <- function(doc, page_url) {
  if (is.null(doc)) return(tibble::tibble(url = character(), status = integer(), ok = logical()))

  links  <- xml2::xml_attr(xml2::xml_find_all(doc, "//link[@href]"), "href")
  scripts <- xml2::xml_attr(xml2::xml_find_all(doc, "//script[@src]"), "src")
  asset_urls <- unique(c(links, scripts))
  asset_urls <- asset_urls[!is.na(asset_urls) & nzchar(asset_urls)]

  # Drop data: URIs and anchors
  asset_urls <- asset_urls[!grepl("^(data:|#|javascript:)", asset_urls)]

  # Only CSS / JS / fonts (drop API URLs, RSS feeds, etc.)
  asset_urls <- asset_urls[
    grepl("\\.(css|js|woff2?|ttf|eot|svg|ico|png|jpg)([?#].*)?$", asset_urls) |
      grepl("^https?://.*\\.(css|js)$", asset_urls)
  ]

  # Resolve relative URLs against the PAGE url (xml2 handles `../` correctly)
  asset_urls <- xml2::url_absolute(asset_urls, page_url)
  asset_urls <- unique(asset_urls)

  if (length(asset_urls) == 0L) {
    return(tibble::tibble(url = character(), status = integer(), ok = logical()))
  }

  # Limit to first 30 assets to avoid excessive network calls
  asset_urls <- utils::head(asset_urls, 30L)

  results <- lapply(asset_urls, function(u) {
    st <- tryCatch({
      resp <- httr2::request(u) |>
        httr2::req_method("HEAD") |>
        httr2::req_timeout(10) |>
        httr2::req_error(is_error = \(r) FALSE) |>
        httr2::req_perform()
      httr2::resp_status(resp)
    }, error = function(e) NA_integer_)
    list(url = u, status = st, ok = isTRUE(st >= 200L & st < 400L))
  })

  tibble::tibble(
    url    = vapply(results, `[[`, character(1L), "url"),
    status = vapply(results, `[[`, integer(1L),   "status"),
    ok     = vapply(results, `[[`, logical(1L),   "ok")
  )
}

#' Check Leaflet containers for empty (silent) state.
#' Returns a tibble: n_total, n_empty_with_message, n_empty_silent.
#' @noRd
.check_leaflets <- function(doc, html_text) {
  empty_result <- tibble::tibble(
    n_total            = 0L,
    n_empty_with_message = 0L,
    n_empty_silent     = 0L
  )
  if (is.null(doc)) return(empty_result)

  leaflets <- xml2::xml_find_all(doc, "//div[contains(@class,'leaflet')]")
  n_total  <- length(leaflets)
  if (n_total == 0L) return(empty_result)

  # Count markers or polygon JSON refs in the raw HTML
  has_geodata <- grepl(
    "(leaflet-marker|circleMarker|addPolygons|latlng|coordinates)",
    html_text
  )

  if (has_geodata) {
    # Has geo data — leaflets are populated
    return(tibble::tibble(
      n_total              = n_total,
      n_empty_with_message = 0L,
      n_empty_silent       = 0L
    ))
  }

  # No geo data found — classify each leaflet container
  empty_with_msg <- 0L
  empty_silent   <- 0L
  empty_markers  <- c(
    "no buildings", "no data", "empty", "no records", "not available",
    "nothing to display", "no results"
  )

  for (lf in leaflets) {
    inner_text <- tolower(trimws(xml2::xml_text(lf)))
    # Check sibling/parent context too
    parent_text <- tryCatch(
      tolower(xml2::xml_text(xml2::xml_parent(lf))),
      error = function(e) ""
    )
    combined <- paste(inner_text, parent_text)
    if (any(vapply(empty_markers, grepl, logical(1L), x = combined, fixed = TRUE))) {
      empty_with_msg <- empty_with_msg + 1L
    } else {
      empty_silent <- empty_silent + 1L
    }
  }

  tibble::tibble(
    n_total              = n_total,
    n_empty_with_message = empty_with_msg,
    n_empty_silent       = empty_silent
  )
}

#' Count tables with empty <tbody> (zero <tr> children).
#' @noRd
.check_tables <- function(doc) {
  if (is.null(doc)) return(0L)
  tbodies <- xml2::xml_find_all(doc, "//table/tbody")
  n_empty <- sum(vapply(tbodies, function(tb) {
    length(xml2::xml_find_all(tb, ".//tr")) == 0L
  }, logical(1L)))
  n_empty
}

#' Count broken same-page hash links (#fragment without matching id).
#' @noRd
.check_hash_links <- function(doc) {
  if (is.null(doc)) return(0L)
  anchors <- xml2::xml_attr(xml2::xml_find_all(doc, "//a[@href]"), "href")
  hash_links <- anchors[!is.na(anchors) & grepl("^#", anchors)]
  if (length(hash_links) == 0L) return(0L)

  all_ids <- xml2::xml_attr(xml2::xml_find_all(doc, "//*[@id]"), "id")
  fragments <- sub("^#", "", hash_links)
  sum(!fragments %in% all_ids)
}

#' Format a results tibble to markdown and write to analysis/qa/.
#' @noRd
.format_report <- function(results, base_url) {
  date_str <- format(Sys.Date(), "%Y-%m-%d")
  report_dir  <- file.path("analysis", "qa")
  if (!dir.exists(report_dir)) dir.create(report_dir, recursive = TRUE)
  report_path <- file.path(report_dir, paste0("deploy_validation_", date_str, ".md"))

  lines <- c(
    paste0("# Deploy Validation Report — ", date_str),
    "",
    paste0("**Site:** ", base_url),
    paste0("**Run at:** ", format(Sys.time(), "%Y-%m-%d %H:%M:%S %Z")),
    "",
    "## Summary",
    "",
    paste0(
      "| Page | HTTP | Errors | Silent Empty Leaflets | ",
      "Broken Assets | Empty Tables | Broken Hashes | Verdict |"
    ),
    paste0(
      "|------|------|--------|-----------------------|",
      "--------------|--------------|---------------|---------|"
    )
  )

  for (i in seq_len(nrow(results))) {
    r <- results[i, ]
    row <- paste0(
      "| `", r$url, "` ",
      "| ", r$http_status,
      " | ", r$error_marker_count,
      " | ", r$empty_leaflet_silent,
      " | ", r$broken_asset_count,
      " | ", r$empty_table_count,
      " | ", r$broken_hash_count,
      " | **", r$verdict, "** |"
    )
    lines <- c(lines, row)
  }

  lines <- c(
    lines, "",
    "## Verdict Logic",
    "",
    "- **FAIL**: HTTP != 200, error markers > 0, silent empty leaflets, or 4xx/5xx assets",
    "- **WARN**: broken hash links or empty tables",
    "- **PASS**: all checks clean",
    ""
  )

  writeLines(lines, report_path)
  cli::cli_inform("Report written to {.path {report_path}}")
  invisible(report_path)
}

# ---------------------------------------------------------------------------
# Per-page validation orchestrator
# ---------------------------------------------------------------------------

#' Validate a single page URL and return a one-row data.frame.
#' @noRd
.validate_one <- function(url, base_url) {
  fetched <- .fetch_page(url)
  doc     <- fetched$doc
  body    <- fetched$body
  status  <- fetched$status

  # Error markers
  markers   <- if (nchar(body) > 0L) .check_error_markers(body) else integer(0L)
  n_errors  <- if (length(markers) > 0L) sum(markers) else 0L

  # Assets — resolve relatives against the page URL, not the site root
  assets     <- .check_assets(doc, url)
  n_bad_assets <- if (nrow(assets) > 0L) sum(!assets$ok, na.rm = TRUE) else 0L

  # Leaflets
  leaflet_info    <- .check_leaflets(doc, body)
  n_empty_silent  <- leaflet_info$n_empty_silent

  # Tables
  n_empty_tables <- .check_tables(doc)

  # Hash links
  n_broken_hashes <- .check_hash_links(doc)

  # Verdict
  is_fail <- (
    isTRUE(is.na(status) || status != 200L) ||
    n_errors > 0L ||
    n_empty_silent > 0L ||
    n_bad_assets > 0L
  )
  is_warn <- !is_fail && (n_broken_hashes > 0L || n_empty_tables > 0L)
  verdict <- dplyr::case_when(
    is_fail ~ "FAIL",
    is_warn ~ "WARN",
    TRUE    ~ "PASS"
  )

  cli::cli_bullets(c(
    " " = "HTTP:          {status}",
    " " = "Error markers: {n_errors}",
    " " = "Bad assets:    {n_bad_assets}",
    " " = "Empty leaflets (silent): {n_empty_silent}",
    " " = "Empty tables:  {n_empty_tables}",
    " " = "Broken hashes: {n_broken_hashes}",
    " " = "Verdict:       {verdict}"
  ))

  data.frame(
    url                  = url,
    http_status          = as.integer(status),
    error_marker_count   = as.integer(n_errors),
    empty_leaflet_silent = as.integer(n_empty_silent),
    broken_asset_count   = as.integer(n_bad_assets),
    empty_table_count    = as.integer(n_empty_tables),
    broken_hash_count    = as.integer(n_broken_hashes),
    verdict              = verdict,
    stringsAsFactors     = FALSE
  )
}
