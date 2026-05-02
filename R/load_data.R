#' Load ACD snapshot data
#'
#' Single entry point for both local and remote-hosted Parquet snapshots.
#' Local mode reads from `inst/extdata/` (offline, fast, ships with package).
#' Remote mode queries Parquet hosted on GitHub Pages via DuckDB httpfs —
#' DuckDB issues HTTP range requests, downloading only the byte ranges the
#' query needs (predicate / projection pushdown).
#'
#' @section Architecture:
#' Stage 1 (POC): `source = "local"` reads committed Parquet from `inst/extdata`.
#' Stage 2 (preview): `source = "remote"` reads from GitHub Pages — same Parquet,
#'   served from `docs/data/`. No code change needed downstream.
#' Stage 3 (scale): switch `REMOTE_BASE_URL` to HuggingFace `hf://datasets/...`
#'   or S3/R2 once the dataset outgrows GitHub Pages limits.
#'
#' @param layer One of `"joined"`, `"zones"`, `"buildings"`, or `"addresses"`.
#'   The `"addresses"` layer resolves to
#'   `addresses_<ADDRESSES_SNAPSHOT_DATE>.parquet` (snapshot 2026-05-02,
#'   291 k rows from `ogdwien:ADRESSENOGD`).
#' @param source One of "local" (default) or "remote". Local reads from
#'   `system.file("extdata", ...)`. Remote reads via duckplyr from
#'   `REMOTE_BASE_URL`.
#' @param snapshot_date ISO date string. Defaults to `SNAPSHOT_DATE` for
#'   joined/zones/buildings layers; for `"addresses"` it defaults to
#'   `ADDRESSES_SNAPSHOT_DATE` ("2026-05-02").
#' @param collect Logical. If `TRUE` (default for "local"), pull everything
#'   into memory as an `sf` data frame. If `FALSE` (default for "remote"),
#'   return a lazy duckplyr frame so further verbs push down to DuckDB.
#'
#' @return For `collect = TRUE`, an `sf` object. For `collect = FALSE`,
#'   a lazy duckplyr frame (call `dplyr::collect()` to materialise).
#'
#' @examples
#' \dontrun{
#'   # Local mode — full snapshot loaded into memory as sf
#'   joined_local <- load_acd_data("joined", source = "local")
#'
#'   # Addresses layer — 291 k rows, ACD + street/house/PLZ lookup table
#'   addr <- load_acd_data("addresses", source = "local")
#'
#'   # Remote mode — query against Parquet on GitHub Pages, no full download
#'   load_acd_data("joined", source = "remote", collect = FALSE) |>
#'     dplyr::filter(district == "Leopoldstadt",
#'                   link_status == "in_zone") |>
#'     dplyr::count(zone_type) |>
#'     dplyr::collect()
#' }
#'
#' @export
load_acd_data <- function(layer = c("joined", "zones", "buildings", "addresses"),
                          source = c("local", "remote"),
                          snapshot_date = NULL,
                          collect = NULL) {
  layer <- rlang::arg_match(layer)
  source <- rlang::arg_match(source)

  # Default snapshot_date depends on the layer
  if (is.null(snapshot_date)) {
    snapshot_date <- if (layer == "addresses") ADDRESSES_SNAPSHOT_DATE else SNAPSHOT_DATE
  }

  if (is.null(collect)) {
    collect <- (source == "local")
  }

  filename <- glue::glue("{layer}_{snapshot_date}.parquet")

  if (source == "local") {
    path <- .resolve_local_parquet(filename)
    if (!file.exists(path)) {
      cli::cli_abort(c(
        "Local snapshot not found: {.file {path}}",
        "i" = "Run the fetch + join pipeline to materialise it, or use {.code source = 'remote'}."
      ))
    }
    if (!requireNamespace("arrow", quietly = TRUE)) {
      cli::cli_abort("Package {.pkg arrow} required for local Parquet read.")
    }
    df <- arrow::read_parquet(path)
    if (collect) {
      return(.maybe_to_sf(df))
    }
    return(df)
  }

  url <- glue::glue("{REMOTE_BASE_URL}/{filename}")
  if (!requireNamespace("duckplyr", quietly = TRUE)) {
    cli::cli_abort(c(
      "Package {.pkg duckplyr} required for remote Parquet queries.",
      "i" = "Add to {.file DESCRIPTION} Imports and {.file default.R} r_pkgs."
    ))
  }

  lazy <- duckplyr::read_parquet_duckdb(url)

  if (collect) {
    df <- dplyr::collect(lazy)
    return(.maybe_to_sf(df))
  }
  lazy
}

#' Resolve local Parquet path
#'
#' Tries installed package, then dev tree (pkgload::load_all), then a path
#' relative to the calling file. Mirrors the `.cached_rds()` pattern in the
#' `maps` template.
#' @keywords internal
#' @noRd
.resolve_local_parquet <- function(filename) {
  installed <- system.file("extdata", filename, package = "acd")
  if (nzchar(installed)) return(installed)

  dev_path <- tryCatch(
    file.path(find.package("acd"), "inst", "extdata", filename),
    error = function(e) ""
  )
  if (nzchar(dev_path) && file.exists(dev_path)) return(dev_path)

  here_path <- file.path("inst", "extdata", filename)
  if (file.exists(here_path)) return(here_path)

  ""
}

#' Convert duckplyr/tibble result back to sf if it carries a geometry column
#' @keywords internal
#' @noRd
.maybe_to_sf <- function(df) {
  geom_cols <- c("building_geom", "zone_geom", "geometry")
  hit <- intersect(geom_cols, names(df))
  if (length(hit) == 0) return(df)

  first_hit <- hit[[1L]]
  if (inherits(df[[first_hit]], "sfc")) {
    return(sf::st_as_sf(df))
  }
  if (is.character(df[[first_hit]])) {
    return(sf::st_as_sf(df, wkt = first_hit, crs = CRS_WORKING))
  }
  df
}
