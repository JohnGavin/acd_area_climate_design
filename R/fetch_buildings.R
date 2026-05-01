#' Fetch Vienna building inventory from OGD WFS
#'
#' Downloads the `ogdwien:GEBAEUDEOGD` layer from the Vienna Open Government
#' Data WFS endpoint, caches the raw GeoJSON to `data-raw/`, and returns a
#' valid sf object in EPSG:31287 (Austria Lambert, the working CRS).
#'
#' The function is cache-first: if the cache file already exists for the
#' requested snapshot date (and optional bbox hash) it is read from disk
#' without any network call unless `force = TRUE`.
#'
#' @param snapshot_date Character scalar. ISO-8601 date string used as a
#'   cache-file suffix and provenance metadata. Defaults to `SNAPSHOT_DATE`.
#' @param max_features Integer or `NULL`. When set, adds a WFS `count`
#'   parameter. `NULL` fetches the full layer (~100 k buildings for Vienna).
#' @param bbox Numeric vector of length 4 `c(xmin, ymin, xmax, ymax)` in
#'   **EPSG:31256** (native CRS) to restrict the spatial extent. When `NULL`
#'   the full layer is requested. Providing a bbox changes the cache filename
#'   to include an 8-character hash of the bbox values so multiple sub-regions
#'   can coexist in cache.
#' @param force Logical. When `TRUE`, ignore any existing cache file.
#'
#' @return An sf object (MULTIPOLYGON) in EPSG:31287 with all WFS attributes.
#'   The attribute `snapshot_date` is set on the returned object.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Smoke test — first 500 buildings, no spatial filter
#' bldg <- fetch_buildings(max_features = 500)
#'
#' # Sub-region fetch for Vienna 1st district (bbox in EPSG:31256)
#' bbox_1st <- c(597000, 337000, 602000, 341000)
#' bldg_1st <- fetch_buildings(bbox = bbox_1st)
#' }
fetch_buildings <- function(
    snapshot_date = SNAPSHOT_DATE,
    max_features  = NULL,
    bbox          = NULL,
    force         = FALSE
) {
  # Derive cache filename — append bbox hash when a spatial filter is active
  bbox_suffix <- if (!is.null(bbox)) {
    stopifnot(is.numeric(bbox), length(bbox) == 4L)
    paste0("_", substr(digest::digest(bbox, algo = "crc32"), 1L, 8L))
  } else {
    ""
  }

  cache_path <- file.path(
    "data-raw",
    paste0("buildings_", snapshot_date, bbox_suffix, ".geojson")
  )

  if (file.exists(cache_path) && !force) {
    cli::cli_inform("Reading buildings from cache: {.path {cache_path}}")
    result <- sf::st_read(cache_path, quiet = TRUE)
    result <- sf::st_transform(result, crs = CRS_WORKING)
    result <- sf::st_make_valid(result)
    attr(result, "snapshot_date") <- snapshot_date
    return(result)
  }

  cli::cli_inform("Fetching buildings from WFS ({WFS_BASE_URL})")

  # Build WFS query parameters
  query_params <- list(
    service      = "WFS",
    version      = "2.0.0",
    request      = "GetFeature",
    typeNames    = LAYER_BUILDINGS,
    srsName      = paste0("EPSG:", CRS_NATIVE),
    outputFormat = "application/json"
  )
  if (!is.null(max_features)) {
    query_params$count <- as.integer(max_features)
  }
  if (!is.null(bbox)) {
    # WFS 2.0 BBOX format: minx,miny,maxx,maxy,CRS
    query_params$bbox <- paste0(
      paste(bbox, collapse = ","),
      ",EPSG:", CRS_NATIVE
    )
  }

  resp <- tryCatch(
    httr2::request(WFS_BASE_URL) |>
      httr2::req_url_query(!!!query_params) |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      cli::cli_abort(
        c(
          "Network error while fetching buildings from WFS.",
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

  dir.create(dirname(cache_path), showWarnings = FALSE, recursive = TRUE)
  writeBin(httr2::resp_body_raw(resp), cache_path)
  cli::cli_inform("Buildings cached at {.path {cache_path}}")

  result <- sf::st_read(cache_path, quiet = TRUE)
  result <- sf::st_transform(result, crs = CRS_WORKING)
  result <- sf::st_make_valid(result)

  attr(result, "snapshot_date") <- snapshot_date
  result
}
