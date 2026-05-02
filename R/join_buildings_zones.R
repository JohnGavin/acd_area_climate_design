#' @importFrom rlang .data
NULL

# ── confidence_tier distance thresholds (metres, EPSG:31287) ─────────────────
# Tier A: centroid inside zone AND >5 m from boundary → "in_zone_high"
# Tier B: centroid inside zone AND ≤5 m from boundary → "in_zone_boundary"
# Tier C: centroid outside, within 25 m of nearest zone → "outside_boundary"
# Tier D: centroid outside, 25–500 m from nearest zone → "outside_nearby"
# Tier E: centroid outside, >500 m from any zone       → "outside_far"
TIER_BOUNDARY_INSIDE_M  <- 5L    # inside buildings ≤5 m from edge = Tier B
TIER_BOUNDARY_OUTSIDE_M <- 25L   # outside buildings ≤25 m from zone = Tier C
TIER_NEARBY_OUTSIDE_M   <- 500L  # outside buildings ≤500 m from zone = Tier D


#' Spatial join of buildings to ACD zones
#'
#' Assigns each building to its primary ACD energy-planning zone, computes
#' diagnostic fields (`n_overlapping_zones`, `overlap_fraction`), classifies
#' the spatial relationship as a `link_status` factor, and adds a
#' `confidence_tier` factor summarising each building's proximity to the
#' nearest zone boundary.
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
#' @section confidence_tier:
#' A 5-level factor derived from the distance of each building centroid to the
#' nearest zone boundary (EPSG:31287 metres). Replaces the defunct
#' `acd_agreement` field.
#'
#' | Tier | Label | Definition |
#' |------|-------|------------|
#' | A | `A_in_zone_high`      | inside zone AND > `TIER_BOUNDARY_INSIDE_M` m from boundary |
#' | B | `B_in_zone_boundary`  | inside zone AND ≤ `TIER_BOUNDARY_INSIDE_M` m from boundary |
#' | C | `C_outside_boundary`  | outside zone AND ≤ `TIER_BOUNDARY_OUTSIDE_M` m from nearest zone |
#' | D | `D_outside_nearby`    | outside zone, `TIER_BOUNDARY_OUTSIDE_M`–`TIER_NEARBY_OUTSIDE_M` m |
#' | E | `E_outside_far`       | outside zone AND > `TIER_NEARBY_OUTSIDE_M` m from any zone |
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
#'     data (the building registry Adress-Code, NOT a zone membership flag)}
#'   \item{district}{`<chr>` — `BEZ` district name from buildings}
#'   \item{year_built}{`<int>` — `BAUJAHR`}
#'   \item{n_stories}{`<int>` — `GESCH_ANZ`}
#'   \item{address}{`<chr>` — composed from `STRNAML` / `VONN` / `BISN`}
#'   \item{zone_id}{`<chr>` — `ERPLABEL` of primary intersecting zone,
#'     or `NA` if none}
#'   \item{zone_area_ha}{`<dbl>` — `FL_ERP / 10000`}
#'   \item{zone_district}{`<chr>` — `BEZNR` from zone}
#'   \item{zone_pre_linked_gebid}{`<chr>` — `GEBID` from the zone record}
#'   \item{zone_legal_url}{`<chr>` — `WEBLINK_VO` URL}
#'   \item{link_status}{`<fct>` — spatial relationship category}
#'   \item{n_overlapping_zones}{`<int>` — number of overlapping zones}
#'   \item{overlap_fraction}{`<dbl>` — fraction of building footprint inside zones}
#'   \item{nearest_zone_dist_m}{`<dbl>` — distance (metres) from building centroid
#'     to nearest zone boundary; always non-negative}
#'   \item{inside_any_zone}{`<lgl>` — `TRUE` if centroid falls inside at least
#'     one zone polygon}
#'   \item{confidence_tier}{`<fct>` — 5-level proximity tier (A–E; see section
#'     *confidence_tier*)}
#' }
#'
#' @export
#'
#' @seealso [confidence_tier_summary()] for tier counts and percentages,
#'   [case_tier()] to subset by tier letter,
#'   [confidence_tier_by_district()] for a district × tier pivot,
#'   [link_status_summary()] for counts by spatial relationship.
#'
#' @examples
#' \dontrun{
#' zones     <- fetch_acd_zones(max_features = 100)
#' buildings <- fetch_buildings(max_features = 500)
#' joined    <- join_buildings_zones(buildings, zones)
#' dplyr::count(joined, link_status)
#' confidence_tier_summary(joined)
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
  buildings <- buildings |>
    dplyr::rename(
      dplyr::any_of(c(
        building_id = "OBJECTID",
        acd_native  = "ACD",
        district    = "BEZ",
        year_built  = "BAUJAHR",
        n_stories   = "GESCH_ANZ"
      ))
    ) |>
    dplyr::mutate(
      building_id = as.character(.data$building_id)
    )

  zones <- zones |>
    dplyr::rename(
      dplyr::any_of(c(
        zone_id               = "ERPLABEL",
        zone_area_m2          = "FL_ERP",
        zone_district         = "BEZNR",
        zone_pre_linked_gebid = "GEBID",
        zone_legal_url        = "WEBLINK_VO"
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

  primary_zone_id        <- zone_attrs$zone_id[primary_idx]
  primary_zone_area_m2   <- if ("zone_area_m2" %in% names(zone_attrs))
    zone_attrs$zone_area_m2[primary_idx] else rep(NA_real_, length(primary_idx))
  primary_zone_district  <- if ("zone_district" %in% names(zone_attrs))
    zone_attrs$zone_district[primary_idx] else rep(NA_character_, length(primary_idx))
  primary_zone_gebid     <- if ("zone_pre_linked_gebid" %in% names(zone_attrs))
    zone_attrs$zone_pre_linked_gebid[primary_idx] else rep(NA_character_, length(primary_idx))
  primary_zone_legal_url <- if ("zone_legal_url" %in% names(zone_attrs))
    zone_attrs$zone_legal_url[primary_idx] else rep(NA_character_, length(primary_idx))

  # ── 8. overlap_fraction: area of footprint inside ANY overlapping zone ────────
  n_bldg           <- nrow(buildings)
  overlap_fraction <- numeric(n_bldg)

  bldg_geom  <- sf::st_geometry(buildings)
  zone_geom  <- sf::st_geometry(zones)
  bldg_areas <- sf::st_area(bldg_geom)

  for (i in seq_len(n_bldg)) {
    zone_idx_i <- intersects_list[[i]]
    if (length(zone_idx_i) == 0L || !valid_geom[[i]]) {
      overlap_fraction[[i]] <- 0.0
      next
    }
    union_zones_i    <- sf::st_union(zone_geom[zone_idx_i])
    intersect_area_i <- sf::st_area(
      suppressWarnings(sf::st_intersection(bldg_geom[i], union_zones_i))
    )
    total_intersect      <- if (length(intersect_area_i) == 0L) 0 else sum(intersect_area_i)
    bldg_area_i          <- as.numeric(bldg_areas[[i]])
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

  # ── 10. inside_any_zone logical flag ─────────────────────────────────────────
  inside_any_zone <- n_overlapping > 0L

  # ── 11. Distance from centroid to nearest zone boundary ──────────────────────
  # Compute zone boundary as a single MULTILINESTRING via st_boundary(st_union).
  # st_distance from centroid to this boundary gives distance to nearest edge
  # for both inside and outside buildings (always non-negative).
  # st_make_valid is applied before st_union to avoid TopologyException on
  # self-touching or slightly invalid zone polygons in the WFS dataset.
  zone_geom_valid <- sf::st_make_valid(zone_geom)
  zones_boundary  <- sf::st_boundary(sf::st_union(zone_geom_valid))
  dist_to_boundary <- as.numeric(
    sf::st_distance(centroids, zones_boundary)[, 1]
  )

  # ── 12. confidence_tier factor ───────────────────────────────────────────────
  # For inside buildings: dist_to_boundary = distance to nearest zone edge
  # For outside buildings: dist_to_boundary = distance to nearest zone edge
  # (same computation — st_boundary of the unioned polygon is the outer edge)
  confidence_tier <- dplyr::case_when(
    inside_any_zone  & dist_to_boundary >  TIER_BOUNDARY_INSIDE_M  ~ "A_in_zone_high",
    inside_any_zone  & dist_to_boundary <= TIER_BOUNDARY_INSIDE_M  ~ "B_in_zone_boundary",
    !inside_any_zone & dist_to_boundary <= TIER_BOUNDARY_OUTSIDE_M ~ "C_outside_boundary",
    !inside_any_zone & dist_to_boundary <= TIER_NEARBY_OUTSIDE_M   ~ "D_outside_nearby",
    TRUE                                                             ~ "E_outside_far"
  )
  confidence_tier <- factor(
    confidence_tier,
    levels = c(
      "A_in_zone_high", "B_in_zone_boundary",
      "C_outside_boundary", "D_outside_nearby", "E_outside_far"
    )
  )

  # ── 13. Assemble output sf ────────────────────────────────────────────────────
  joined <- buildings |>
    dplyr::mutate(
      year_built            = as.integer(.data$year_built),
      n_stories             = if ("n_stories" %in% names(buildings))
        as.integer(.data$n_stories) else NA_integer_,
      address               = if ("address" %in% names(buildings))
        as.character(.data$address) else NA_character_,
      acd_native            = if ("acd_native" %in% names(buildings))
        as.character(.data$acd_native) else NA_character_,
      zone_id               = primary_zone_id,
      zone_area_ha          = as.double(primary_zone_area_m2) / 10000,
      zone_district         = as.character(primary_zone_district),
      zone_pre_linked_gebid = as.character(primary_zone_gebid),
      zone_legal_url        = as.character(primary_zone_legal_url),
      link_status           = link_status,
      n_overlapping_zones   = as.integer(n_overlapping),
      overlap_fraction      = overlap_fraction,
      nearest_zone_dist_m   = dist_to_boundary,
      inside_any_zone       = inside_any_zone,
      confidence_tier       = confidence_tier
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
        "nearest_zone_dist_m",
        "inside_any_zone",
        "confidence_tier"
      ))
    )

  joined
}


#' Summarise confidence tier distribution
#'
#' Returns a tibble with one row per `confidence_tier` level, with counts,
#' percentages, and brand hex colours for visualisation.
#'
#' @param joined Output of [join_buildings_zones()].
#'
#' @return A tibble with columns:
#' \describe{
#'   \item{tier}{`<chr>` — the 5-level tier code (A–E)}
#'   \item{n_buildings}{`<int>` — count of buildings at this tier}
#'   \item{pct}{`<dbl>` — percentage of total buildings, rounded to 1 d.p.}
#'   \item{color}{`<chr>` — hex colour for visualisation}
#' }
#'
#' @export
#'
#' @examples
#' \dontrun{
#' joined <- join_buildings_zones(fetch_buildings(), fetch_acd_zones())
#' confidence_tier_summary(joined)
#' }
confidence_tier_summary <- function(joined) {
  tier_colors <- c(
    "A_in_zone_high"     = "#2ca02c",
    "B_in_zone_boundary" = "#bcbd22",
    "C_outside_boundary" = "#ff7f0e",
    "D_outside_nearby"   = "#9467bd",
    "E_outside_far"      = "#7f7f7f"
  )

  all_levels <- names(tier_colors)

  raw <- joined |>
    sf::st_drop_geometry() |>
    dplyr::count(.data$confidence_tier, name = "n_buildings")

  tibble::tibble(
    confidence_tier = factor(all_levels, levels = all_levels)
  ) |>
    dplyr::left_join(raw, by = "confidence_tier") |>
    dplyr::mutate(
      n_buildings = dplyr::coalesce(.data$n_buildings, 0L),
      pct         = round(100 * .data$n_buildings / sum(.data$n_buildings), 1),
      color       = tier_colors[as.character(.data$confidence_tier)],
      tier        = substr(as.character(.data$confidence_tier), 1L, 1L)
    ) |>
    dplyr::select("tier", "confidence_tier", "n_buildings", "pct", "color")
}


#' Find orphan zones — zones with no building centroid inside them
#'
#' Returns the subset of `zones` for which no building centroid falls within
#' the zone polygon.
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

  coverage <- sf::st_contains(zones, centroids)
  n_inside <- lengths(coverage)

  zones[n_inside == 0L, ]
}
