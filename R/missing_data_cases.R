#' @importFrom rlang .data
NULL

# ── link_status colour palette (shared) ─────────────────────────────────────
.LINK_STATUS_COLORS <- c(
  "in_zone"            = "#2ca02c",
  "outside_any_zone"   = "#7f7f7f",
  "straddles_boundary" = "#ff7f0e",
  "multiple_zones"     = "#9467bd",
  "invalid_geometry"   = "#d62728",
  "orphan_zone"        = "#1f77b4"
)


# ── Per-case subset helpers ──────────────────────────────────────────────────

#' Buildings that are cleanly inside exactly one zone
#'
#' Returns buildings with `link_status == "in_zone"`. These are the
#' "happy-path" rows: one-to-one building–zone match.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#'
#' @return Subset of `joined` where `link_status == "in_zone"`.
#' @export
case_in_zone <- function(joined) {
  joined[joined$link_status == "in_zone", ]
}


#' Buildings whose centroid falls outside every ACD zone
#'
#' These buildings are not errors: the ACD coverage does not cover all of
#' Vienna. They legitimately lie outside the energy-planning area.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#' @param vienna_boundary An optional sf object representing the Vienna city
#'   boundary (or any clipping polygon) in EPSG:31287. When supplied, the
#'   result is clipped to within that boundary using
#'   [sf::st_intersection()]. Useful for excluding buildings that straddle
#'   the city boundary itself.
#'
#' @return Subset of `joined` where `link_status == "outside_any_zone"`,
#'   optionally clipped to `vienna_boundary`.
#' @export
case_outside_any_zone <- function(joined, vienna_boundary = NULL) {
  out <- joined[joined$link_status == "outside_any_zone", ]
  if (!is.null(vienna_boundary)) {
    out <- suppressWarnings(sf::st_intersection(out, vienna_boundary))
  }
  out
}


#' Buildings that straddle an ACD zone boundary
#'
#' Returns buildings with `link_status == "straddles_boundary"` — i.e. the
#' building footprint overlaps a zone but the overlap fraction is strictly
#' between 5 % and 95 %.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#'
#' @return Subset of `joined` where `link_status == "straddles_boundary"`.
#' @export
case_straddles_boundary <- function(joined) {
  joined[joined$link_status == "straddles_boundary", ]
}


#' Buildings whose centroid falls inside more than one zone
#'
#' Returns buildings with `link_status == "multiple_zones"`. This occurs when
#' zone polygons overlap each other and a building centroid lands in the
#' overlapping region.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#'
#' @return Subset of `joined` where `link_status == "multiple_zones"`.
#' @export
case_multiple_zones <- function(joined) {
  joined[joined$link_status == "multiple_zones", ]
}


#' ACD zones that contain no building centroids
#'
#' Thin wrapper around [find_orphan_zones()]. Returns the zones side of the
#' "missing link" problem: zones that exist in the energy plan but have no
#' associated buildings.
#'
#' @param zones An sf object of ACD zones (EPSG:31287).
#' @param buildings An sf object of buildings (EPSG:31287).
#'
#' @return Subset of `zones` with no building centroids inside.
#' @export
case_orphan_zones <- function(zones, buildings) {
  find_orphan_zones(zones, buildings)
}


#' Buildings with invalid geometries
#'
#' Returns buildings with `link_status == "invalid_geometry"`. These should
#' be investigated before any spatial analysis; [sf::st_make_valid()] may
#' resolve some cases.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#'
#' @return Subset of `joined` where `link_status == "invalid_geometry"`.
#' @export
case_invalid_geometry <- function(joined) {
  joined[joined$link_status == "invalid_geometry", ]
}


# ── Summary tibble ───────────────────────────────────────────────────────────

#' Summarise building counts by link_status
#'
#' Returns a tibble with one row per `link_status` level (including
#' `orphan_zone` with `n = 0` if absent from `joined`), sorted by descending
#' count, with percentage and brand hex colour for the dashboard legend.
#'
#' @param joined An sf object produced by [join_buildings_zones()].
#'
#' @return A tibble with columns:
#' \describe{
#'   \item{link_status}{`<fct>` — one of the six diagnostic categories}
#'   \item{n_buildings}{`<int>` — count of buildings with this status}
#'   \item{pct}{`<dbl>` — percentage of total buildings (0–100)}
#'   \item{color}{`<chr>` — hex colour for visualisation}
#' }
#'
#' @export
link_status_summary <- function(joined) {
  all_levels <- names(.LINK_STATUS_COLORS)

  raw <- joined |>
    sf::st_drop_geometry() |>
    dplyr::count(.data$link_status, name = "n_buildings", .drop = FALSE)

  # Ensure every level appears (orphan_zone will be absent from buildings join)
  complete_tbl <- tibble::tibble(
    link_status = factor(all_levels, levels = all_levels)
  ) |>
    dplyr::left_join(raw, by = "link_status") |>
    dplyr::mutate(
      n_buildings = dplyr::coalesce(.data$n_buildings, 0L),
      pct         = 100 * .data$n_buildings / sum(.data$n_buildings),
      color       = .LINK_STATUS_COLORS[as.character(.data$link_status)]
    ) |>
    dplyr::arrange(dplyr::desc(.data$n_buildings))

  complete_tbl
}
