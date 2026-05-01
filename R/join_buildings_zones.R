#' @importFrom rlang .data
NULL

#' Spatial join of buildings to ACD zones
#'
#' Assigns each building to its primary ACD energy-planning zone, computes
#' diagnostic fields (`n_overlapping_zones`, `overlap_fraction`), and
#' classifies the relationship as a `link_status` factor.
#'
#' Both inputs must already be in EPSG:31287 (Austria Lambert). The join uses
#' **building centroids** to determine primary zone membership, plus a
#' full-footprint area intersection to compute `overlap_fraction`.
#'
#' @section link_status logic:
#' Priority order (checked in order; first match wins):
#' 1. `invalid_geometry` — `sf::st_is_valid(building)` is `FALSE`
#' 2. `outside_any_zone` — centroid intersects no zone
#' 3. `multiple_zones` — centroid intersects > 1 zone
#' 4. `straddles_boundary` — `overlap_fraction` strictly between 0.05 and 0.95
#' 5. `in_zone` — everything else
#'
#' @param buildings An sf object with building footprints in EPSG:31287.
#'   Must contain at minimum the columns returned by [fetch_buildings()]:
#'   `OBJECTID`, `BAUJAHR`, `HOEHE`, `ADRESSE`.
#' @param zones An sf object with ACD zone polygons in EPSG:31287.
#'   Must contain at minimum: `ERPLABEL`, `ERPTYP`, `ERPRECHTSTAT`.
#'
#' @return An sf object (same geometry as `buildings`) with the joined schema
#'   defined in `STUBS.md`:
#'   `building_id`, `building_geom`, `district`, `year_built`, `height_m`,
#'   `address`, `zone_id`, `zone_type`, `legal_status`, `link_status`,
#'   `n_overlapping_zones`, `overlap_fraction`.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' zones    <- fetch_acd_zones(max_features = 100)
#' buildings <- fetch_buildings(max_features = 500)
#' joined   <- join_buildings_zones(buildings, zones)
#' dplyr::count(joined, link_status)
#' }
join_buildings_zones <- function(buildings, zones) {
  # ── 1. CRS guard ─────────────────────────────────────────────────────────────
  b_crs <- sf::st_crs(buildings)$epsg
  z_crs <- sf::st_crs(zones)$epsg

  if (is.null(b_crs) || is.null(z_crs)) {
    cli::cli_abort(
      "Both {.arg buildings} and {.arg zones} must have an EPSG CRS set."
    )
  }
  if (b_crs != CRS_WORKING || z_crs != CRS_WORKING) {
    cli::cli_abort(
      c(
        "Both inputs must be in EPSG:{CRS_WORKING}.",
        "i" = "{.arg buildings} CRS: EPSG:{b_crs}",
        "i" = "{.arg zones} CRS: EPSG:{z_crs}"
      )
    )
  }

  # ── 2. Rename / select WFS columns to canonical schema names ─────────────────
  # NOTE: These column names are assumed from the OGD WFS schema inspection.
  # See uncertainty note at end of file.
  buildings <- buildings |>
    dplyr::rename(
      building_id = dplyr::any_of(c("OBJECTID", "objectid")),
      year_built  = dplyr::any_of(c("BAUJAHR", "baujahr")),
      height_m    = dplyr::any_of(c("HOEHE", "hoehe", "GEBHOEHE", "gebhoehe")),
      address     = dplyr::any_of(c("ADRESSE", "adresse"))
    ) |>
    # Ensure building_id is character
    dplyr::mutate(
      building_id = as.character(.data$building_id)
    )

  zones <- zones |>
    dplyr::rename(
      zone_id      = dplyr::any_of(c("ERPLABEL", "erplabel")),
      zone_type    = dplyr::any_of(c("ERPTYP", "erptyp")),
      legal_status = dplyr::any_of(c("ERPRECHTSTAT", "erprechtstat"))
    )

  # ── 3. Building validity flag ─────────────────────────────────────────────────
  valid_geom <- sf::st_is_valid(buildings)

  # ── 4. Centroids (suppress warnings for invalid geoms) ───────────────────────
  suppressWarnings(
    centroids <- sf::st_centroid(sf::st_geometry(buildings))
  )

  # ── 5. Centroid-to-zone spatial intersection ─────────────────────────────────
  intersects_list <- sf::st_intersects(centroids, zones)
  n_overlapping   <- lengths(intersects_list)

  # ── 6. Primary zone index (first match, or NA) ────────────────────────────────
  primary_idx <- vapply(
    intersects_list,
    FUN       = function(x) if (length(x) == 0L) NA_integer_ else x[[1L]],
    FUN.VALUE = integer(1L)
  )

  # ── 7. Pull zone attributes for the primary match ────────────────────────────
  zone_attrs <- zones |>
    sf::st_drop_geometry() |>
    dplyr::select(
      dplyr::any_of(c("zone_id", "zone_type", "legal_status"))
    )

  primary_zone_id     <- zone_attrs$zone_id[primary_idx]
  primary_zone_type   <- zone_attrs$zone_type[primary_idx]
  primary_legal_stat  <- zone_attrs$legal_status[primary_idx]

  # ── 8. overlap_fraction: area of footprint inside ANY overlapping zone ────────
  n_bldg          <- nrow(buildings)
  overlap_fraction <- numeric(n_bldg)

  bldg_geom <- sf::st_geometry(buildings)
  zone_geom <- sf::st_geometry(zones)

  bldg_areas <- sf::st_area(bldg_geom)

  for (i in seq_len(n_bldg)) {
    zone_idx_i <- intersects_list[[i]]
    if (length(zone_idx_i) == 0L || !valid_geom[[i]]) {
      overlap_fraction[[i]] <- 0.0
      next
    }
    # Union of all overlapping zone footprints intersected with this building
    union_zones_i    <- sf::st_union(zone_geom[zone_idx_i])
    intersect_area_i <- sf::st_area(
      suppressWarnings(sf::st_intersection(bldg_geom[[i]], union_zones_i))
    )
    total_intersect <- if (length(intersect_area_i) == 0L) 0 else sum(intersect_area_i)
    bldg_area_i     <- as.numeric(bldg_areas[[i]])
    overlap_fraction[[i]] <- if (bldg_area_i > 0) {
      min(as.numeric(total_intersect) / bldg_area_i, 1.0)
    } else {
      0.0
    }
  }

  # ── 9. link_status classification ────────────────────────────────────────────
  link_status <- dplyr::case_when(
    !valid_geom                                        ~ "invalid_geometry",
    n_overlapping == 0L                                ~ "outside_any_zone",
    n_overlapping > 1L                                 ~ "multiple_zones",
    overlap_fraction > 0.05 & overlap_fraction < 0.95 ~ "straddles_boundary",
    TRUE                                               ~ "in_zone"
  )
  link_status <- factor(
    link_status,
    levels = c(
      "in_zone", "outside_any_zone", "straddles_boundary",
      "multiple_zones", "orphan_zone", "invalid_geometry"
    )
  )

  # ── 10. Derive district from building centroid (placeholder: NA for now) ──────
  # Full district assignment requires the Vienna district boundary layer
  # (BEZIRKSGRENZEOGD). For the POC this is left as NA and can be populated
  # by a separate spatial join in a downstream target.
  district <- NA_character_

  # ── 11. Assemble output sf ────────────────────────────────────────────────────
  # Start from buildings sf to preserve geometry and CRS
  buildings |>
    dplyr::mutate(
      building_geom       = sf::st_geometry(buildings),
      district            = district,
      year_built          = as.integer(.data$year_built),
      height_m            = as.double(.data$height_m),
      address             = as.character(.data$address),
      zone_id             = primary_zone_id,
      zone_type           = primary_zone_type,
      legal_status        = primary_legal_stat,
      link_status         = link_status,
      n_overlapping_zones = as.integer(n_overlapping),
      overlap_fraction    = overlap_fraction
    ) |>
    dplyr::select(
      dplyr::any_of(c(
        "building_id", "building_geom", "district",
        "year_built", "height_m", "address",
        "zone_id", "zone_type", "legal_status",
        "link_status", "n_overlapping_zones", "overlap_fraction"
      ))
    )
}


#' Find orphan zones — zones with no building centroid inside them
#'
#' Returns the subset of `zones` for which no building centroid falls within
#' the zone polygon. These are used to populate the "Orphan zones" dashboard
#' tab (i.e., the `orphan_zone` case on the zones side of the join).
#'
#' @param zones An sf object of ACD zones in EPSG:31287.
#' @param buildings An sf object of buildings in EPSG:31287.
#'
#' @return An sf object — the subset of `zones` that contain no building
#'   centroids.
#'
#' @export
#'
#' @examples
#' \dontrun{
#' zones     <- fetch_acd_zones()
#' buildings <- fetch_buildings()
#' orphans   <- find_orphan_zones(zones, buildings)
#' nrow(orphans)
#' }
find_orphan_zones <- function(zones, buildings) {
  suppressWarnings(
    centroids <- sf::st_centroid(sf::st_geometry(buildings))
  )

  # For each zone, count how many centroids fall inside
  coverage <- sf::st_contains(zones, centroids)
  n_inside <- lengths(coverage)

  zones[n_inside == 0L, ]
}
