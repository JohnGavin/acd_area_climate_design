test_that("join_buildings_zones produces correct link_status for all cases", {
  # ── Synthetic zones in EPSG:31287 ──────────────────────────────────────────
  # Zone 1: 100×100 m square, bottom-left at (200000, 400000)
  # Zone 2: 100×100 m square, bottom-left at (200050, 400000)
  #         (overlaps zone 1 by 50 m in x — the overlap strip is used for the
  #          "multiple_zones" building)
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zone2_wkt <- "POLYGON((200050 400000, 200150 400000, 200150 400100, 200050 400100, 200050 400000))"

  zones <- sf::st_sf(
    ERPLABEL    = c("Z1", "Z2"),
    FL_ERP      = c(10000, 10000),
    BEZNR       = c("01", "02"),
    GEBID       = c(NA_character_, NA_character_),
    WEBLINK_VO  = c(NA_character_, NA_character_),
    geometry     = sf::st_sfc(
      sf::st_as_sfc(zone1_wkt)[[1]],
      sf::st_as_sfc(zone2_wkt)[[1]],
      crs = 31287
    )
  )

  # ── Synthetic buildings ────────────────────────────────────────────────────
  sq <- function(cx, cy, s = 5) {
    sf::st_polygon(list(matrix(
      c(cx - s, cy - s,
        cx + s, cy - s,
        cx + s, cy + s,
        cx - s, cy + s,
        cx - s, cy - s),
      ncol = 2, byrow = TRUE
    )))
  }

  # B1 — entirely inside zone 1 (centroid well inside Z1)
  b1 <- sq(200020, 400050)

  # B2 — entirely inside zone 2 (centroid well inside Z2)
  b2 <- sq(200130, 400050)

  # B3 — centroid at x=200075, inside both zone 1 and zone 2 → multiple_zones
  b3 <- sq(200075, 400050)

  # B4 — centroid far outside both zones → outside_any_zone
  b4 <- sq(201000, 400050)

  # B5 — straddles boundary: building footprint crosses Z1 boundary but
  #       centroid is inside Z1. We make it large enough that only ~30% of
  #       the footprint is inside Z1 (overlap 0.05 < frac < 0.95).
  b5 <- sq(200020, 400050, s = 25)

  # B6 — invalid geometry (self-intersecting bowtie)
  b6 <- sf::st_polygon(list(matrix(
    c(200200, 400200,
      200210, 400210,
      200210, 400200,
      200200, 400210,
      200200, 400200),
    ncol = 2, byrow = TRUE
  )))

  buildings <- sf::st_sf(
    OBJECTID    = 1:6,
    ACD         = c("Z1", "Z2", NA_character_, NA_character_, "Z1", NA_character_),
    BAUJAHR     = c(1990L, 2000L, 1985L, 1975L, 2010L, 1960L),
    GESCH_ANZ   = c(3L, 2L, 4L, 1L, 3L, 2L),
    BEZ         = paste0("Bezirk ", 1:6),
    STRNAML     = paste0("Testgasse ", 1:6),
    VONN        = as.character(1:6),
    BISN        = c(NA, NA, NA, NA, NA, NA),
    address     = paste0("Testgasse ", 1:6),
    geometry    = sf::st_sfc(b1, b2, b3, b4, b5, b6, crs = 31287)
  )

  # ── Run the join ───────────────────────────────────────────────────────────
  joined <- join_buildings_zones(buildings, zones)

  # ── Schema checks ─────────────────────────────────────────────────────────
  required_cols <- c(
    "building_id", "acd_native", "district", "year_built", "n_stories",
    "address", "zone_id", "zone_area_ha", "zone_district",
    "zone_pre_linked_gebid", "zone_legal_url",
    "link_status", "n_overlapping_zones", "overlap_fraction",
    "nearest_zone_dist_m", "inside_any_zone", "confidence_tier"
  )
  expect_true(
    all(required_cols %in% names(joined)),
    label = paste(
      "Missing columns:",
      paste(setdiff(required_cols, names(joined)), collapse = ", ")
    )
  )

  # acd_agreement must NOT be present (it was removed in Stage 1a)
  expect_false(
    "acd_agreement" %in% names(joined),
    label = "acd_agreement column must not be present (removed in Stage 1a)"
  )

  # ── link_status assignments ────────────────────────────────────────────────
  ls <- joined$link_status[order(as.integer(joined$building_id))]

  expect_equal(as.character(ls[1]), "in_zone",
               label = "B1 (inside Z1) should be in_zone")
  expect_equal(as.character(ls[2]), "in_zone",
               label = "B2 (inside Z2) should be in_zone")
  expect_equal(as.character(ls[3]), "multiple_zones",
               label = "B3 (centroid in both zones) should be multiple_zones")
  expect_equal(as.character(ls[4]), "outside_any_zone",
               label = "B4 (centroid outside all zones) should be outside_any_zone")
  expect_equal(as.character(ls[5]), "straddles_boundary",
               label = "B5 (large building straddling Z1 boundary) should be straddles_boundary")
  expect_equal(as.character(ls[6]), "invalid_geometry",
               label = "B6 (self-intersecting bowtie) should be invalid_geometry")
})


test_that("overlap_fraction is within [0, 1] for all buildings", {
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zones <- sf::st_sf(
    ERPLABEL   = "Z1",
    FL_ERP     = 10000,
    BEZNR      = "01",
    GEBID      = NA_character_,
    WEBLINK_VO = NA_character_,
    geometry   = sf::st_sfc(sf::st_as_sfc(zone1_wkt)[[1]], crs = 31287)
  )

  sq <- function(cx, cy, s = 5) {
    sf::st_polygon(list(matrix(
      c(cx - s, cy - s, cx + s, cy - s, cx + s, cy + s,
        cx - s, cy + s, cx - s, cy - s),
      ncol = 2, byrow = TRUE
    )))
  }

  buildings <- sf::st_sf(
    OBJECTID  = 1:3,
    ACD       = c("Z1", NA_character_, NA_character_),
    BAUJAHR   = c(2000L, 2000L, 2000L),
    GESCH_ANZ = c(3L, 3L, 3L),
    BEZ       = c("Bezirk 1", "Bezirk 1", "Bezirk 1"),
    STRNAML   = c("A-Gasse", "B-Gasse", "C-Gasse"),
    VONN      = c("1", "1", "1"),
    BISN      = c(NA, NA, NA),
    address   = c("A-Gasse 1", "B-Gasse 1", "C-Gasse 1"),
    geometry  = sf::st_sfc(
      sq(200050, 400050),         # entirely inside
      sq(199990, 400050, s = 20), # partially inside
      sq(201000, 400050),         # entirely outside
      crs = 31287
    )
  )

  joined <- join_buildings_zones(buildings, zones)

  expect_true(
    all(joined$overlap_fraction >= 0 & joined$overlap_fraction <= 1),
    label = "overlap_fraction must be in [0, 1]"
  )
})


test_that("CRS mismatch raises an error", {
  zone_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zones <- sf::st_sf(
    ERPLABEL   = "Z1",
    FL_ERP     = 10000,
    BEZNR      = "01",
    GEBID      = NA_character_,
    WEBLINK_VO = NA_character_,
    geometry   = sf::st_sfc(sf::st_as_sfc(zone_wkt)[[1]], crs = 31287)
  )

  buildings_wgs84 <- sf::st_sf(
    OBJECTID  = 1L,
    ACD       = NA_character_,
    BAUJAHR   = 2000L,
    GESCH_ANZ = 3L,
    BEZ       = "Bezirk 1",
    STRNAML   = "A-Gasse",
    VONN      = "1",
    BISN      = NA_character_,
    address   = "A-Gasse 1",
    geometry  = sf::st_sfc(
      sf::st_point(c(16.37, 48.21)),
      crs = 4326
    )
  )

  expect_error(
    join_buildings_zones(buildings_wgs84, zones),
    regexp = "31287"
  )
})


test_that("find_orphan_zones returns zones with no building centroids", {
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zone2_wkt <- "POLYGON((201000 400000, 201100 400000, 201100 400100, 201000 400100, 201000 400000))"

  zones <- sf::st_sf(
    ERPLABEL   = c("Z1", "Z2"),
    FL_ERP     = c(10000, 10000),
    BEZNR      = c("01", "02"),
    GEBID      = c(NA_character_, NA_character_),
    WEBLINK_VO = c(NA_character_, NA_character_),
    geometry   = sf::st_sfc(
      sf::st_as_sfc(zone1_wkt)[[1]],
      sf::st_as_sfc(zone2_wkt)[[1]],
      crs = 31287
    )
  )

  buildings <- sf::st_sf(
    OBJECTID  = 1L,
    ACD       = NA_character_,
    BAUJAHR   = 2000L,
    GESCH_ANZ = 3L,
    BEZ       = "Bezirk 1",
    STRNAML   = "A-Gasse",
    VONN      = "1",
    BISN      = NA_character_,
    address   = "A-Gasse 1",
    geometry  = sf::st_sfc(
      sf::st_point(c(200050, 400050)),
      crs = 31287
    )
  )

  orphans <- find_orphan_zones(zones, buildings)

  expect_equal(nrow(orphans), 1L, label = "Z2 should be the sole orphan zone")
  expect_equal(orphans$ERPLABEL, "Z2")
})


test_that("link_status_summary returns all six levels with correct structure", {
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zones <- sf::st_sf(
    ERPLABEL   = "Z1",
    FL_ERP     = 10000,
    BEZNR      = "01",
    GEBID      = NA_character_,
    WEBLINK_VO = NA_character_,
    geometry   = sf::st_sfc(sf::st_as_sfc(zone1_wkt)[[1]], crs = 31287)
  )

  buildings <- sf::st_sf(
    OBJECTID  = 1:2,
    ACD       = c("Z1", NA_character_),
    BAUJAHR   = c(2000L, 1990L),
    GESCH_ANZ = c(3L, 2L),
    BEZ       = c("Bezirk 1", "Bezirk 2"),
    STRNAML   = c("A-Gasse", "B-Gasse"),
    VONN      = c("1", "1"),
    BISN      = c(NA, NA),
    address   = c("A-Gasse 1", "B-Gasse 1"),
    geometry  = sf::st_sfc(
      sf::st_polygon(list(matrix(
        c(200020, 400020, 200030, 400020, 200030, 400030, 200020, 400030, 200020, 400020),
        ncol = 2, byrow = TRUE
      ))),
      sf::st_polygon(list(matrix(
        c(201000, 401000, 201010, 401000, 201010, 401010, 201000, 401010, 201000, 401000),
        ncol = 2, byrow = TRUE
      ))),
      crs = 31287
    )
  )

  joined  <- join_buildings_zones(buildings, zones)
  summary <- link_status_summary(joined)

  expect_true(inherits(summary, "data.frame"))
  expect_true(all(c("link_status", "n_buildings", "pct", "color") %in% names(summary)))

  expected_levels <- c(
    "in_zone", "outside_any_zone", "straddles_boundary",
    "multiple_zones", "orphan_zone", "invalid_geometry"
  )
  expect_setequal(as.character(summary$link_status), expected_levels)

  total_n <- sum(summary$n_buildings)
  if (total_n > 0) {
    expect_equal(sum(summary$pct), 100, tolerance = 0.01)
  }

  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", summary$color)))
})


# ── confidence_tier tests ────────────────────────────────────────────────────

# Helper: two-zone fixture with one building per confidence tier
.make_tier_fixtures <- function() {
  # Zone A (200 x 200 m) well away from zone edges so tier A is reachable
  zone_wkt <- "POLYGON((200000 400000, 200200 400000, 200200 400200, 200000 400200, 200000 400000))"
  zones <- sf::st_sf(
    ERPLABEL   = "Z1",
    FL_ERP     = 40000,
    BEZNR      = "01",
    GEBID      = NA_character_,
    WEBLINK_VO = NA_character_,
    geometry   = sf::st_sfc(sf::st_as_sfc(zone_wkt)[[1]], crs = 31287)
  )

  sq <- function(cx, cy, s = 3) {
    sf::st_polygon(list(matrix(
      c(cx - s, cy - s, cx + s, cy - s, cx + s, cy + s,
        cx - s, cy + s, cx - s, cy - s),
      ncol = 2, byrow = TRUE
    )))
  }

  # Tier A: inside zone, centroid far from boundary (100 m inside)
  bA <- sq(200100, 400100)

  # Tier B: inside zone, centroid close to boundary (2 m inside left edge at x=200000)
  bB <- sq(200002, 400100)

  # Tier C: outside zone, centroid within 25 m (15 m to the right of right edge x=200200)
  bC <- sq(200215, 400100)

  # Tier D: outside zone, centroid 100 m to the right of right edge → 100 m away
  bD <- sq(200300, 400100)

  # Tier E: outside zone, centroid 600 m to the right → clearly outside
  bE <- sq(200800, 400100)

  buildings <- sf::st_sf(
    OBJECTID  = 1:5,
    ACD       = rep(NA_character_, 5),
    BAUJAHR   = rep(2000L, 5),
    GESCH_ANZ = rep(3L, 5),
    BEZ       = paste0("Bezirk ", 1:5),
    STRNAML   = paste0("Gasse ", 1:5),
    VONN      = as.character(1:5),
    BISN      = rep(NA_character_, 5),
    address   = paste0("Gasse ", 1:5, " 1"),
    geometry  = sf::st_sfc(bA, bB, bC, bD, bE, crs = 31287)
  )

  list(zones = zones, buildings = buildings)
}


test_that("confidence_tier factor has 5 levels and all levels are populated", {
  f      <- .make_tier_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  expect_true("confidence_tier" %in% names(joined),
              label = "confidence_tier column must be present")
  expect_true(is.factor(joined$confidence_tier),
              label = "confidence_tier must be a factor")

  expected_levels <- c(
    "A_in_zone_high", "B_in_zone_boundary",
    "C_outside_boundary", "D_outside_nearby", "E_outside_far"
  )
  expect_equal(levels(joined$confidence_tier), expected_levels,
               label = "confidence_tier must have correct 5 levels in order")
})


test_that("confidence_tier assigns correct tier to each synthetic building", {
  f      <- .make_tier_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  tiers <- as.character(joined$confidence_tier[order(as.integer(joined$building_id))])

  expect_equal(tiers[1], "A_in_zone_high",
               label = "Building 1 (100 m inside zone) should be Tier A")
  expect_equal(tiers[2], "B_in_zone_boundary",
               label = "Building 2 (2 m from boundary, inside) should be Tier B")
  expect_equal(tiers[3], "C_outside_boundary",
               label = "Building 3 (15 m outside zone) should be Tier C")
  expect_equal(tiers[4], "D_outside_nearby",
               label = "Building 4 (100 m outside zone) should be Tier D")
  expect_equal(tiers[5], "E_outside_far",
               label = "Building 5 (600 m outside zone) should be Tier E")
})


test_that("nearest_zone_dist_m is non-negative for all buildings", {
  f      <- .make_tier_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  expect_true(
    all(joined$nearest_zone_dist_m >= 0),
    label = "nearest_zone_dist_m must be non-negative"
  )
})


test_that("inside_any_zone is consistent with link_status", {
  f      <- .make_tier_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  # inside_any_zone TRUE → link_status should be in_zone, straddles_boundary, or multiple_zones
  # inside_any_zone FALSE → link_status should be outside_any_zone or invalid_geometry
  inside_statuses  <- c("in_zone", "straddles_boundary", "multiple_zones")
  outside_statuses <- c("outside_any_zone", "invalid_geometry")

  expect_true(
    all(joined$link_status[joined$inside_any_zone] %in% inside_statuses),
    label = "inside_any_zone=TRUE buildings must have in-zone link_status"
  )
  expect_true(
    all(joined$link_status[!joined$inside_any_zone] %in% outside_statuses),
    label = "inside_any_zone=FALSE buildings must have outside link_status"
  )
})


test_that("confidence_tier_summary returns 5 rows with pcts summing to 100", {
  f      <- .make_tier_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)
  summ   <- confidence_tier_summary(joined)

  expect_true(inherits(summ, "data.frame"),
              label = "confidence_tier_summary must return a data.frame")
  expect_true(
    all(c("tier", "confidence_tier", "n_buildings", "pct", "color") %in% names(summ)),
    label = "expected columns missing from confidence_tier_summary"
  )
  expect_equal(nrow(summ), 5L,
               label = "confidence_tier_summary should have 5 rows")

  expect_equal(sum(summ$pct), 100, tolerance = 0.1,
               label = "pct column in confidence_tier_summary must sum to 100")

  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", summ$color)),
              label = "color column must be valid hex colours")
})
