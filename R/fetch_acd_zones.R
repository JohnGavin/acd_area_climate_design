#' Fetch ACD Energieraumpläne (energy planning zones) from Vienna OGD WFS
#'
#' Downloads the `ogdwien:ENERGIERAUMPLANOGD` layer from the Vienna Open
#' Government Data WFS endpoint, caches the raw GeoJSON to `data-raw/`, and
#' returns a valid sf object in EPSG:31287 (Austria Lambert, the working CRS).
#'
#' The function is cache-first: if the file already exists for the requested
#' snapshot date it is read from disk without any network call unless
#' `force = TRUE`.
#'
#' @param snapshot_date Character scalar. ISO-8601 date string used both as a
#'   cache-file suffix and as provenance metadata on the returned object.
#'   Defaults to `SNAPSHOT_DATE` (defined in `R/snapshot.R`).
#' @param max_features Integer or `NULL`. When set, adds a WFS `count`
#'   parameter to limit the number of features returned. Useful for smoke
#'   tests (`max_features = 100`). `NULL` fetches the full layer.
#' @param force Logical. When `TRUE`, ignore any existing cache file and
#'   re-download from the WFS endpoint.
#'
#' @return An sf object (MULTIPOLYGON) in EPSG:31287 with WFS attributes
#'   including `OBJECTID`, `ERPLABEL`, `BEZNR`, `GEBID`, `FL_ERP`, `PLANNR`,
#'   `BEARB_DATUM`, `WEBLINK_VO`, and `SHAPE` (geometry). The attribute
#'   `snapshot_date` is set on the returned object.
#'
#' @note The real schema does **not** include `ERPTYP` or `ERPRECHTSTAT`.
#'   Zone type and legal status must be inferred from `ERPLABEL` or
#'   `WEBLINK_VO` — this is left as future work outside the POC scope.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Smoke test — fetch first 100 zones only
#' zones <- fetch_acd_zones(max_features = 100)
#'
#' # Full fetch for snapshot date
#' zones <- fetch_acd_zones()
#' }
fetch_acd_zones <- function(
    snapshot_date = SNAPSHOT_DATE,
    max_features  = NULL,
    force         = FALSE
) {
  cache_path <- file.path(
    "data-raw",
    paste0("zones_", snapshot_date, ".geojson")
  )

  if (file.exists(cache_path) && !force) {
    cli::cli_inform("Reading zones from cache: {.path {cache_path}}")
    result <- sf::st_read(cache_path, quiet = TRUE)
    result <- sf::st_transform(result, crs = CRS_WORKING)
    result <- sf::st_make_valid(result)
    attr(result, "snapshot_date") <- snapshot_date
    return(result)
  }

  cli::cli_inform("Fetching zones from WFS ({WFS_BASE_URL})")

  # Build query params
  query_params <- list(
    service      = "WFS",
    version      = "2.0.0",
    request      = "GetFeature",
    typeNames    = LAYER_ZONES,
    srsName      = paste0("EPSG:", CRS_NATIVE),
    outputFormat = "application/json"
  )
  if (!is.null(max_features)) {
    query_params$count <- as.integer(max_features)
  }

  resp <- tryCatch(
    httr2::request(WFS_BASE_URL) |>
      httr2::req_url_query(!!!query_params) |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      cli::cli_abort(
        c(
          "Network error while fetching ACD zones from WFS.",
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

  # Write raw bytes to cache before parsing, so a partial parse error
  # does not leave us without the file.
  dir.create(dirname(cache_path), showWarnings = FALSE, recursive = TRUE)
  writeBin(httr2::resp_body_raw(resp), cache_path)
  cli::cli_inform("Zones cached at {.path {cache_path}}")

  result <- sf::st_read(cache_path, quiet = TRUE)
  result <- sf::st_transform(result, crs = CRS_WORKING)
  result <- sf::st_make_valid(result)

  attr(result, "snapshot_date") <- snapshot_date
  result
}
