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
  # Helper: make a small square polygon centred at (cx, cy) with half-side s
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
  #       Centre at (200020, 400050), half-side 25 → extends to 199995..200045
  #       in x; Z1 starts at 200000, so ~20/50 = 40% inside → straddles.
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
    "acd_agreement"
  )
  expect_true(
    all(required_cols %in% names(joined)),
    label = paste(
      "Missing columns:",
      paste(setdiff(required_cols, names(joined)), collapse = ", ")
    )
  )

  # ── link_status assignments ────────────────────────────────────────────────
  ls <- joined$link_status[order(as.integer(joined$building_id))]

  # B1 inside Z1 only — expect in_zone OR straddles depending on overlap_fraction
  # (B1 is 10×10 m, entirely inside Z1's 100×100 m → overlap_fraction ≈ 1.0)
  expect_equal(as.character(ls[1]), "in_zone",
               label = "B1 (inside Z1) should be in_zone")

  # B2 inside Z2 only
  expect_equal(as.character(ls[2]), "in_zone",
               label = "B2 (inside Z2) should be in_zone")

  # B3 centroid inside both zones → multiple_zones
  expect_equal(as.character(ls[3]), "multiple_zones",
               label = "B3 (centroid in both zones) should be multiple_zones")

  # B4 centroid outside all zones → outside_any_zone
  expect_equal(as.character(ls[4]), "outside_any_zone",
               label = "B4 (centroid outside all zones) should be outside_any_zone")

  # B5 straddles boundary (large footprint, only ~40% inside Z1)
  expect_equal(as.character(ls[5]), "straddles_boundary",
               label = "B5 (large building straddling Z1 boundary) should be straddles_boundary")

  # B6 invalid geometry
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

  # Buildings in wrong CRS (EPSG:4326 / WGS84)
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

  # Building only in Z1, none in Z2
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

  # All six levels must be present (even if n = 0)
  expected_levels <- c(
    "in_zone", "outside_any_zone", "straddles_boundary",
    "multiple_zones", "orphan_zone", "invalid_geometry"
  )
  expect_setequal(as.character(summary$link_status), expected_levels)

  # Percentages sum to ~100 (modulo zero-count rows)
  total_n <- sum(summary$n_buildings)
  if (total_n > 0) {
    expect_equal(sum(summary$pct), 100, tolerance = 0.01)
  }

  # Colors are hex strings
  expect_true(all(grepl("^#[0-9a-fA-F]{6}$", summary$color)))
})


# ── acd_agreement cross-validation tests ────────────────────────────────────

# Shared helper used across multiple acd_agreement tests
.make_acd_fixtures <- function() {
  zone_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zones <- sf::st_sf(
    ERPLABEL   = "Z1",
    FL_ERP     = 10000,
    BEZNR      = "01",
    GEBID      = NA_character_,
    WEBLINK_VO = NA_character_,
    geometry   = sf::st_sfc(sf::st_as_sfc(zone_wkt)[[1]], crs = 31287)
  )

  sq <- function(cx, cy, s = 5) {
    sf::st_polygon(list(matrix(
      c(cx - s, cy - s, cx + s, cy - s, cx + s, cy + s,
        cx - s, cy + s, cx - s, cy - s),
      ncol = 2, byrow = TRUE
    )))
  }

  # B1: spatial=in_zone,        acd_native="Z1"          → agree_in_zone
  # B2: spatial=outside_any_zone, acd_native=NA           → agree_no_zone
  # B3: spatial=in_zone,        acd_native=NA/""          → spatial_only
  # B4: spatial=outside_any_zone, acd_native="Z1" (populated) → acd_only
  buildings <- sf::st_sf(
    OBJECTID  = 1:4,
    ACD       = c("Z1", NA_character_, NA_character_, "Z1"),
    BAUJAHR   = rep(2000L, 4),
    GESCH_ANZ = rep(3L, 4),
    BEZ       = paste0("Bezirk ", 1:4),
    STRNAML   = paste0("Gasse ", 1:4),
    VONN      = as.character(1:4),
    BISN      = rep(NA_character_, 4),
    address   = paste0("Gasse ", 1:4, " ", 1:4),
    geometry  = sf::st_sfc(
      sq(200050, 400050),  # B1: inside Z1
      sq(201000, 400050),  # B2: outside Z1
      sq(200050, 400050),  # B3: inside Z1 (same spot, different ACD)
      sq(201000, 400050),  # B4: outside Z1 (but ACD says yes)
      crs = 31287
    )
  )

  list(zones = zones, buildings = buildings)
}


test_that("acd_agreement column exists and is a factor with 4 expected levels", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  expect_true("acd_agreement" %in% names(joined),
              label = "acd_agreement column must be present")
  expect_true(is.factor(joined$acd_agreement),
              label = "acd_agreement must be a factor")

  expected_levels <- c("agree_in_zone", "agree_no_zone", "spatial_only", "acd_only")
  expect_setequal(levels(joined$acd_agreement), expected_levels)
})


test_that("B1: spatial=in_zone AND acd_native populated → agree_in_zone", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  b1 <- joined[joined$building_id == "1", ]
  expect_equal(as.character(b1$acd_agreement), "agree_in_zone",
               label = "B1 should be agree_in_zone")
})


test_that("B2: spatial=outside_any_zone AND acd_native empty/NA → agree_no_zone", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  b2 <- joined[joined$building_id == "2", ]
  expect_equal(as.character(b2$acd_agreement), "agree_no_zone",
               label = "B2 should be agree_no_zone")
})


test_that("B3: spatial=in_zone AND acd_native empty → spatial_only", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  b3 <- joined[joined$building_id == "3", ]
  expect_equal(as.character(b3$acd_agreement), "spatial_only",
               label = "B3 should be spatial_only")
})


test_that("B4: spatial=outside_any_zone AND acd_native populated → acd_only", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)

  b4 <- joined[joined$building_id == "4", ]
  expect_equal(as.character(b4$acd_agreement), "acd_only",
               label = "B4 should be acd_only")
})


test_that("acd_agreement_summary returns 4 rows with counts summing to 100 pct", {
  f      <- .make_acd_fixtures()
  joined <- join_buildings_zones(f$buildings, f$zones)
  summ   <- acd_agreement_summary(joined)

  expect_true(inherits(summ, "data.frame"),
              label = "acd_agreement_summary must return a data.frame")
  expect_true(all(c("acd_agreement", "n_buildings", "pct") %in% names(summ)),
              label = "expected columns missing from acd_agreement_summary")

  # All 4 levels present (the fixture produces all 4)
  expect_equal(nrow(summ), 4L,
               label = "acd_agreement_summary should have 4 rows — one per level")

  # Percentages sum to 100
  expect_equal(sum(summ$pct), 100, tolerance = 0.1,
               label = "pct column in acd_agreement_summary must sum to 100")
})
