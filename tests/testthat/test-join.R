test_that("join_buildings_zones produces correct link_status for all cases", {
  # ── Synthetic zones in EPSG:31287 ──────────────────────────────────────────
  # Zone 1: 100×100 m square, bottom-left at (200000, 400000)
  # Zone 2: 100×100 m square, bottom-left at (200050, 400000)
  #         (overlaps zone 1 by 50 m in x — the overlap strip is used for the
  #          "multiple_zones" building)
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zone2_wkt <- "POLYGON((200050 400000, 200150 400000, 200150 400100, 200050 400100, 200050 400000))"

  zones <- sf::st_sf(
    zone_id      = c("Z1", "Z2"),
    zone_type    = c("Fernwaerme", "Waermepumpe"),
    legal_status = c("district_heating_mandatory", "heat_pump_required"),
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
    building_id = as.character(1:6),
    OBJECTID    = 1:6,
    BAUJAHR     = c(1990L, 2000L, 1985L, 1975L, 2010L, 1960L),
    HOEHE       = c(10.5, 8.0, 12.3, 5.0, 9.9, 7.7),
    ADRESSE     = paste0("Strasse ", 1:6),
    geometry    = sf::st_sfc(b1, b2, b3, b4, b5, b6, crs = 31287)
  )

  # ── Run the join ───────────────────────────────────────────────────────────
  joined <- join_buildings_zones(buildings, zones)

  # ── Schema checks ─────────────────────────────────────────────────────────
  required_cols <- c(
    "building_id", "district", "year_built", "height_m", "address",
    "zone_id", "zone_type", "legal_status",
    "link_status", "n_overlapping_zones", "overlap_fraction"
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
    zone_id      = "Z1",
    zone_type    = "Fernwaerme",
    legal_status = "district_heating_mandatory",
    geometry     = sf::st_sfc(sf::st_as_sfc(zone1_wkt)[[1]], crs = 31287)
  )

  sq <- function(cx, cy, s = 5) {
    sf::st_polygon(list(matrix(
      c(cx - s, cy - s, cx + s, cy - s, cx + s, cy + s,
        cx - s, cy + s, cx - s, cy - s),
      ncol = 2, byrow = TRUE
    )))
  }

  buildings <- sf::st_sf(
    building_id = as.character(1:3),
    OBJECTID    = 1:3,
    BAUJAHR     = c(2000L, 2000L, 2000L),
    HOEHE       = c(10.0, 10.0, 10.0),
    ADRESSE     = c("A", "B", "C"),
    geometry    = sf::st_sfc(
      sq(200050, 400050),       # entirely inside
      sq(199990, 400050, s = 20), # partially inside
      sq(201000, 400050),       # entirely outside
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
    zone_id      = "Z1",
    zone_type    = "Fernwaerme",
    legal_status = "district_heating_mandatory",
    geometry     = sf::st_sfc(sf::st_as_sfc(zone_wkt)[[1]], crs = 31287)
  )

  # Buildings in wrong CRS (EPSG:4326 / WGS84)
  buildings_wgs84 <- sf::st_sf(
    building_id = "1",
    OBJECTID    = 1L,
    BAUJAHR     = 2000L,
    HOEHE       = 10.0,
    ADRESSE     = "A",
    geometry    = sf::st_sfc(
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
    zone_id      = c("Z1", "Z2"),
    zone_type    = c("Fernwaerme", "Waermepumpe"),
    legal_status = c("district_heating_mandatory", "heat_pump_required"),
    geometry     = sf::st_sfc(
      sf::st_as_sfc(zone1_wkt)[[1]],
      sf::st_as_sfc(zone2_wkt)[[1]],
      crs = 31287
    )
  )

  # Building only in Z1, none in Z2
  buildings <- sf::st_sf(
    OBJECTID = 1L,
    BAUJAHR  = 2000L,
    HOEHE    = 10.0,
    ADRESSE  = "A",
    geometry = sf::st_sfc(
      sf::st_point(c(200050, 400050)),
      crs = 31287
    )
  )

  orphans <- find_orphan_zones(zones, buildings)

  expect_equal(nrow(orphans), 1L, label = "Z2 should be the sole orphan zone")
  expect_equal(orphans$zone_id, "Z2")
})


test_that("link_status_summary returns all six levels with correct structure", {
  zone1_wkt <- "POLYGON((200000 400000, 200100 400000, 200100 400100, 200000 400100, 200000 400000))"
  zones <- sf::st_sf(
    zone_id      = "Z1",
    zone_type    = "Fernwaerme",
    legal_status = "district_heating_mandatory",
    geometry     = sf::st_sfc(sf::st_as_sfc(zone1_wkt)[[1]], crs = 31287)
  )

  buildings <- sf::st_sf(
    OBJECTID    = 1:2,
    BAUJAHR     = c(2000L, 1990L),
    HOEHE       = c(10.0, 8.0),
    ADRESSE     = c("A", "B"),
    geometry    = sf::st_sfc(
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
