#' Fetch Vienna district boundaries from OGD WFS
#'
#' Downloads the `ogdwien:BEZIRKSGRENZEOGD` layer from the Vienna Open
#' Government Data WFS endpoint (23 Bezirke), caches the raw GeoJSON to
#' `data-raw/`, and returns a valid sf object in EPSG:31287 (Austria Lambert,
#' the working CRS).
#'
#' The function is cache-first: if the file already exists for the requested
#' snapshot date it is read from disk without any network call unless
#' `force = TRUE`.
#'
#' @param snapshot_date Character scalar. ISO-8601 date string used both as a
#'   cache-file suffix and as provenance metadata on the returned object.
#'   Defaults to `SNAPSHOT_DATE` (defined in `R/snapshot.R`).
#' @param force Logical. When `TRUE`, ignore any existing cache file and
#'   re-download from the WFS endpoint.
#'
#' @return An sf object (MULTIPOLYGON) in EPSG:31287 with WFS attributes:
#'   `OBJECTID`, `BEZ`, `BEZNR`, `BEZ_RZ`, `NAMEG` (full German name),
#'   `NAMEK` (short name), `NAMEK_NUM`, `DISTRICT_CODE`,
#'   `STATAUSTRIA_BEZ_CODE`, `STATAUSTRIA_GEM_CODE`, `FLAECHE`, `UMFANG`,
#'   `LABEL`, `AKT_TIMESTAMP`, and `SHAPE` (geometry). The attribute
#'   `snapshot_date` is set on the returned object.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' # Full fetch for snapshot date (23 features)
#' districts <- fetch_districts()
#' nrow(districts)  # 23
#' names(districts)
#' }
fetch_districts <- function(
    snapshot_date = SNAPSHOT_DATE,
    force         = FALSE
) {
  cache_path <- file.path(
    "data-raw",
    paste0("districts_", snapshot_date, ".geojson")
  )

  if (file.exists(cache_path) && !force) {
    cli::cli_inform("Reading districts from cache: {.path {cache_path}}")
    result <- sf::st_read(cache_path, quiet = TRUE)
    result <- sf::st_transform(result, crs = CRS_WORKING)
    result <- sf::st_make_valid(result)
    attr(result, "snapshot_date") <- snapshot_date
    return(result)
  }

  cli::cli_inform("Fetching districts from WFS ({WFS_BASE_URL})")

  query_params <- list(
    service      = "WFS",
    version      = "2.0.0",
    request      = "GetFeature",
    typeNames    = LAYER_DISTRICTS,
    srsName      = paste0("EPSG:", CRS_NATIVE),
    outputFormat = "application/json"
  )

  resp <- tryCatch(
    httr2::request(WFS_BASE_URL) |>
      httr2::req_url_query(!!!query_params) |>
      httr2::req_error(is_error = \(r) FALSE) |>
      httr2::req_perform(),
    error = function(e) {
      cli::cli_abort(
        c(
          "Network error while fetching district boundaries from WFS.",
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
  cli::cli_inform("Districts cached at {.path {cache_path}}")

  result <- sf::st_read(cache_path, quiet = TRUE)
  result <- sf::st_transform(result, crs = CRS_WORKING)
  result <- sf::st_make_valid(result)

  attr(result, "snapshot_date") <- snapshot_date
  result
}
