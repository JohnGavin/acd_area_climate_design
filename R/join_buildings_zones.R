#' @importFrom rlang .data
NULL

#' Spatial join of buildings to ACD zones
#'
#' Assigns each building to its primary ACD energy-planning zone, computes
#' diagnostic fields (`n_overlapping_zones`, `overlap_fraction`), classifies
#' the spatial relationship as a `link_status` factor, and cross-validates the
#' spatial result against the city's pre-linked `ACD` field via `acd_agreement`.
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
#' @section acd_agreement cross-validation:
#' The Vienna city dataset carries a pre-linked `ACD` field on buildings
#' (`ogdwien:GEBAEUDEINFOOGD`). This function cross-validates that city
#' classification against our independent spatial join result:
#'
#' * `agree_in_zone` — both spatial join and city `ACD` say the building is
#'   in a zone (the "happy path" confirming the two approaches agree)
#' * `agree_no_zone` — both agree the building is not in a zone
#' * `spatial_only` — spatial join says in-zone, but city `ACD` is empty/NA
#'   (we say yes, city says no — potential under-coverage in city data)
#' * `acd_only` — city `ACD` says in-zone, but spatial join finds no zone
#'   (city says yes, we say no — potential stale zone geometry or data error)
#'
#' Disagreements (`spatial_only`, `acd_only`) are **interesting findings**,
#' not data errors. Use [case_acd_disagreement()] to extract them.
#'
#' @param buildings An sf object with building footprints in EPSG:31287.
#'   Must contain at minimum the columns returned by [fetch_buildings()]:
#'   `OBJECTID`, `ACD`, `BAUJAHR`, `BEZ`, `GESCH_ANZ`, `STRNAML`,
#'   `VONA`, `VONN`, `BISA`, `BISN`, `STRCD`, `HA_NAME`, `address`.
#' @param zones An sf object with ACD zone polygons in EPSG:31287.
#'   Must contain at minimum: `ERPLABEL`, `BEZNR`, `GEBID`, `FL_ERP`,
#'   `PLANNR`, `BEARB_DATUM`, `WEBLINK_VO`.
#'
#' @return An sf object (same geometry as `buildings`) with columns:
#' \describe{
#'   \item{building_id}{`<chr>` — `OBJECTID` from buildings}
#'   \item{geometry}{sf geometry column preserved from buildings}
#'   \item{acd_native}{`<chr>` — pre-linked `ACD` classification from city
#'     data; may be empty string or `NA` for buildings without a city-side
#'     zone link}
#'   \item{district}{`<chr>` — `BEZ` district name from buildings}
#'   \item{year_built}{`<int>` — `BAUJAHR`}
#'   \item{n_stories}{`<int>` — `GESCH_ANZ` (number of storeys; use as
#'     height proxy in lieu of a height field)}
#'   \item{address}{`<chr>` — composed from `STRNAML` / `VONN` / `BISN`
#'     by [fetch_buildings()]}
#'   \item{zone_id}{`<chr>` — `ERPLABEL` of primary intersecting zone,
#'     or `NA` if none}
#'   \item{zone_area_ha}{`<dbl>` — `FL_ERP / 10000` (zone area in hectares)}
#'   \item{zone_district}{`<chr>` — `BEZNR` district number from zone}
#'   \item{zone_pre_linked_gebid}{`<chr>` — `GEBID` from the zone record
#'     (zone's own claim about which building it is associated with)}
#'   \item{zone_legal_url}{`<chr>` — `WEBLINK_VO` URL to the legal planning
#'     document}
#'   \item{link_status}{`<fct>` — spatial relationship category (see
#'     *link_status logic* section)}
#'   \item{n_overlapping_zones}{`<int>` — number of zones whose centroid
#'     intersects this building}
#'   \item{overlap_fraction}{`<dbl>` — fraction of building footprint area
#'     covered by any overlapping zone; range `[0, 1]`}
#'   \item{acd_agreement}{`<fct>` — cross-validation result comparing our
#'     spatial join to the city's pre-linked `ACD` field (see
#'     *acd_agreement cross-validation* section)}
#' }
#'
#' @export
#'
#' @seealso [acd_agreement_summary()] for a tabular cross-validation summary,
#'   [case_acd_disagreement()] to extract disagreement rows,
#'   [link_status_summary()] for counts by spatial relationship.
#'
#' @examples
#' \dontrun{
#' zones     <- fetch_acd_zones(max_features = 100)
#' buildings <- fetch_buildings(max_features = 500)
#' joined    <- join_buildings_zones(buildings, zones)
#' dplyr::count(joined, link_status)
#' acd_agreement_summary(joined)
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

  # ── 2. Rename WFS columns to canonical schema names ──────────────────────────
  # any_of() is used throughout so the function tolerates either the canonical
  # names (already renamed by a prior call) or the raw WFS column names.
  buildings <- buildings |>
    dplyr::rename(
      dplyr::any_of(c(
        building_id = "OBJECTID",
        acd_native  = "ACD",
        district    = "BEZ",
        year_built  = "BAUJAHR",
        n_stories   = "GESCH_ANZ"
        # address is already composed by fetch_buildings()
      ))
    ) |>
    dplyr::mutate(
      building_id = as.character(.data$building_id)
    )

  zones <- zones |>
    dplyr::rename(
      dplyr::any_of(c(
        zone_id                 = "ERPLABEL",
        zone_area_m2            = "FL_ERP",
        zone_district           = "BEZNR",
        zone_pre_linked_gebid   = "GEBID",
        zone_legal_url          = "WEBLINK_VO"
      ))
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
      dplyr::any_of(c(
        "zone_id", "zone_area_m2", "zone_district",
        "zone_pre_linked_gebid", "zone_legal_url"
      ))
    )

  primary_zone_id             <- zone_attrs$zone_id[primary_idx]
  primary_zone_area_m2        <- if ("zone_area_m2" %in% names(zone_attrs))
    zone_attrs$zone_area_m2[primary_idx] else rep(NA_real_, length(primary_idx))
  primary_zone_district       <- if ("zone_district" %in% names(zone_attrs))
    zone_attrs$zone_district[primary_idx] else rep(NA_character_, length(primary_idx))
  primary_zone_gebid          <- if ("zone_pre_linked_gebid" %in% names(zone_attrs))
    zone_attrs$zone_pre_linked_gebid[primary_idx] else rep(NA_character_, length(primary_idx))
  primary_zone_legal_url      <- if ("zone_legal_url" %in% names(zone_attrs))
    zone_attrs$zone_legal_url[primary_idx] else rep(NA_character_, length(primary_idx))

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
      suppressWarnings(sf::st_intersection(bldg_geom[i], union_zones_i))
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

  # ── 10. acd_agreement cross-validation ───────────────────────────────────────
  # Compares our spatial result to the city's pre-linked ACD field.
  # Disagreements are analytically interesting, not data errors.
  spatial_says_in_zone <- link_status %in%
    c("in_zone", "straddles_boundary", "multiple_zones")

  # Retrieve acd_native from the (already-renamed) buildings data frame.
  # The column may not exist in synthetic test fixtures — default to NA.
  acd_native_raw <- if ("acd_native" %in% names(buildings))
    buildings$acd_native else rep(NA_character_, nrow(buildings))

  acd_says_yes <- !is.na(acd_native_raw) & nzchar(trimws(as.character(acd_native_raw)))

  acd_agreement <- factor(
    dplyr::case_when(
      spatial_says_in_zone  &  acd_says_yes  ~ "agree_in_zone",
      !spatial_says_in_zone & !acd_says_yes  ~ "agree_no_zone",
      spatial_says_in_zone  & !acd_says_yes  ~ "spatial_only",
      !spatial_says_in_zone &  acd_says_yes  ~ "acd_only",
      TRUE ~ NA_character_
    ),
    levels = c("agree_in_zone", "agree_no_zone", "spatial_only", "acd_only")
  )

  # ── 11. Assemble output sf ────────────────────────────────────────────────────
  # Start from buildings sf to preserve geometry and CRS.
  # district is sourced from BEZ (already renamed to district in step 2).
  # n_stories is sourced from GESCH_ANZ (already renamed in step 2).
  joined <- buildings |>
    dplyr::mutate(
      year_built              = as.integer(.data$year_built),
      n_stories               = if ("n_stories" %in% names(buildings))
        as.integer(.data$n_stories) else NA_integer_,
      address                 = if ("address" %in% names(buildings))
        as.character(.data$address) else NA_character_,
      acd_native              = as.character(acd_native_raw),
      zone_id                 = primary_zone_id,
      zone_area_ha            = as.double(primary_zone_area_m2) / 10000,
      zone_district           = as.character(primary_zone_district),
      zone_pre_linked_gebid   = as.character(primary_zone_gebid),
      zone_legal_url          = as.character(primary_zone_legal_url),
      link_status             = link_status,
      n_overlapping_zones     = as.integer(n_overlapping),
      overlap_fraction        = overlap_fraction,
      acd_agreement           = acd_agreement
    ) |>
    dplyr::select(
      dplyr::any_of(c(
        "building_id",
        "acd_native",
        "district",
        "year_built",
        "n_stories",
        "address",
        "zone_id",
        "zone_area_ha",
        "zone_district",
        "zone_pre_linked_gebid",
        "zone_legal_url",
        "link_status",
        "n_overlapping_zones",
        "overlap_fraction",
        "acd_agreement"
      ))
    )

  joined
}


#' Summarise ACD cross-validation agreement
#'
#' Returns a one-row-per-level count of the `acd_agreement` factor from the
#' output of [join_buildings_zones()]. Use this to understand how well the
#' independent spatial join agrees with the city's pre-linked `ACD` field
#' on `ogdwien:GEBAEUDEINFOOGD`.
#'
#' `spatial_only` rows (we say in-zone, city says no) and `acd_only` rows
#' (city says yes, we say no) are analytically interesting disagreements —
#' they may reveal under-coverage in the city data or stale zone geometry.
#'
#' @param joined Output of [join_buildings_zones()].
#'
#' @return A tibble with columns:
#' \describe{
#'   \item{acd_agreement}{`<fct>` — one of `agree_in_zone`, `agree_no_zone`,
#'     `spatial_only`, `acd_only`}
#'   \item{n_buildings}{`<int>` — count of buildings at this level}
#'   \item{pct}{`<dbl>` — percentage of total buildings, rounded to 1 d.p.}
#' }
#'
#' @export
#'
#' @examples
#' \dontrun{
#' joined <- join_buildings_zones(fetch_buildings(), fetch_acd_zones())
#' acd_agreement_summary(joined)
#' }
acd_agreement_summary <- function(joined) {
  joined |>
    sf::st_drop_geometry() |>
    dplyr::count(.data$acd_agreement, name = "n_buildings") |>
    dplyr::mutate(pct = round(100 * .data$n_buildings / sum(.data$n_buildings), 1))
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
