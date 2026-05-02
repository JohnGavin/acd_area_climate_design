#!/usr/bin/env Rscript
# Stage 2: Pull OSM buildings for Vienna and count by district
# Called via: Rscript /private/tmp/acd_stage2_osm/analysis/stage_2/pull_osm_buildings.R

suppressPackageStartupMessages({
  library(osmdata)
  library(sf)
  library(dplyr)
  library(arrow)
  library(tibble)
})

outdir <- "/private/tmp/acd_stage2_osm/analysis/stage_2"

# --- Step 1: Pull OSM buildings for Vienna bounding box ---
vienna_bbox <- c(16.18, 48.12, 16.58, 48.32)  # lon_min, lat_min, lon_max, lat_max

cat("Pulling OSM building features for Vienna...\n")
t0 <- proc.time()

osm_buildings <- tryCatch(
  opq(bbox = vienna_bbox, timeout = 300) |>
    add_osm_feature(key = "building") |>
    osmdata_sf(quiet = FALSE),
  error = function(e) {
    cat("osmdata failed:", conditionMessage(e), "\n")
    NULL
  }
)

elapsed <- (proc.time() - t0)[["elapsed"]]
cat(sprintf("Fetch elapsed: %.1f seconds\n", elapsed))

if (is.null(osm_buildings)) {
  cat("FATAL: osmdata pull failed. Exiting.\n")
  quit(status = 1)
}

poly_count <- nrow(osm_buildings$osm_polygons)
multipoly_count <- nrow(osm_buildings$osm_multipolygons)
cat(sprintf("OSM polygons: %d  multipolygons: %d\n", poly_count, multipoly_count))

# Combine polygons + multipolygons
# Keep only the osm_id geometry column to minimise memory
osm_poly <- osm_buildings$osm_polygons[, "osm_id", drop = FALSE]
osm_multi <- osm_buildings$osm_multipolygons[, "osm_id", drop = FALSE]

# Cast multipolygons to polygon for uniform geometry type
# Use centroid approach so we can just use st_intersects on points
osm_all <- rbind(
  sf::st_cast(sf::st_set_geometry(osm_poly, sf::st_geometry(osm_poly)), "GEOMETRY"),
  sf::st_cast(sf::st_set_geometry(osm_multi, sf::st_geometry(osm_multi)), "GEOMETRY")
)

osm_total <- nrow(osm_all)
cat(sprintf("OSM total Vienna buildings: %d\n", osm_total))

# Save raw count summary
summary_df <- tibble::tibble(
  source    = "OSM",
  bbox      = paste(vienna_bbox, collapse = ","),
  n_polygons = poly_count,
  n_multipolygons = multipoly_count,
  n_total   = osm_total,
  fetch_seconds = round(elapsed, 1),
  fetch_date = as.character(Sys.Date())
)
write.csv(summary_df, file.path(outdir, "osm_total_summary.csv"), row.names = FALSE)
cat("Saved osm_total_summary.csv\n")

# --- Step 2: Load districts layer ---
cat("\nLoading districts layer...\n")
districts_path <- "/private/tmp/acd_stage2_osm/inst/extdata/districts_2026-05-01.parquet"
districts_raw <- arrow::read_parquet(districts_path)

# Detect geometry column (WKT text or sfc object)
geom_col <- intersect(c("geometry", "zone_geom", "building_geom", "geometry_wkt"), names(districts_raw))
if (length(geom_col) == 0) {
  # look for any column ending in _wkt or containing "geom"
  geom_col <- grep("(geom|_wkt)$", names(districts_raw), value = TRUE, ignore.case = TRUE)
}
if (length(geom_col) == 0) {
  cat("Character columns:", paste(names(districts_raw)[sapply(districts_raw, is.character)], collapse = ", "), "\n")
  cat("All columns:", paste(names(districts_raw), collapse = ", "), "\n")
  stop("No geometry column found in districts parquet")
}
cat(sprintf("Using geometry column: %s\n", geom_col[1]))

districts_sf <- sf::st_as_sf(districts_raw, wkt = geom_col[1], crs = 31287)
cat(sprintf("Districts loaded: %d features, columns: %s\n",
            nrow(districts_sf), paste(names(districts_sf), collapse = ", ")))

# Find the district identifier column
# Common names: BEZNR, BEZ_RZ, district, DISTRICT, BEZ
possible_id_cols <- c("BEZNR", "BEZ", "BEZ_RZ", "district", "DISTRICT", "bez", "GEB_BEZIRK")
id_col <- possible_id_cols[possible_id_cols %in% names(districts_sf)][1]
if (is.na(id_col)) {
  cat("Available district columns:", paste(names(districts_sf), collapse = ", "), "\n")
  stop("Cannot identify district ID column")
}
cat(sprintf("Using district ID column: %s\n", id_col))

# --- Step 3: Reproject OSM to EPSG:31287 and compute centroids ---
cat("\nReprojecting OSM buildings to EPSG:31287...\n")
osm_31287 <- sf::st_transform(osm_all, 31287)

cat("Computing centroids...\n")
# Use st_point_on_surface for robustness with complex polygons
osm_centroids <- tryCatch(
  sf::st_point_on_surface(osm_31287),
  warning = function(w) {
    cat("Warning in point_on_surface:", conditionMessage(w), "\n")
    suppressWarnings(sf::st_point_on_surface(osm_31287))
  }
)

# --- Step 4: Spatial intersect centroids with districts ---
cat("Spatial intersection (centroids -> districts)...\n")
districts_31287 <- sf::st_transform(districts_sf, 31287)

hits <- sf::st_intersects(osm_centroids, districts_31287, sparse = TRUE)

osm_district <- vapply(hits, function(idx) {
  if (length(idx) == 0L) NA_character_
  else as.character(districts_31287[[id_col]][idx[1L]])
}, character(1L))

n_matched   <- sum(!is.na(osm_district))
n_unmatched <- sum( is.na(osm_district))
cat(sprintf("Matched: %d  Unmatched (outside districts): %d\n", n_matched, n_unmatched))

# --- Step 5: Aggregate by district ---
osm_by_district <- tibble::tibble(
  district = osm_district
) |>
  dplyr::filter(!is.na(district)) |>
  dplyr::count(district, name = "n_osm") |>
  dplyr::arrange(district)

cat("\nOSM counts by district (top 10):\n")
print(head(osm_by_district, 10))

write.csv(osm_by_district, file.path(outdir, "osm_by_district.csv"), row.names = FALSE)
cat("Saved osm_by_district.csv\n")

# --- Step 6: Load OGD (GEBAEUDEINFOOGD) building counts ---
cat("\nLoading GEBAEUDEINFOOGD joined data...\n")
joined_path <- "/private/tmp/acd_stage2_osm/inst/extdata/joined_2026-05-01.parquet"
joined_raw <- arrow::read_parquet(joined_path)
cat(sprintf("Joined parquet: %d rows, columns: %s\n",
            nrow(joined_raw), paste(head(names(joined_raw), 10), collapse = ", ")))

# Find district column in joined
dist_col_joined <- intersect(c("district", "BEZNR", "BEZ", "GEB_BEZIRK"), names(joined_raw))[1]
cat(sprintf("District column in joined: %s\n", dist_col_joined))

ogd_by_district <- joined_raw |>
  dplyr::count(.data[[dist_col_joined]], name = "n_ogd") |>
  dplyr::rename(district = .data[[dist_col_joined]]) |>
  dplyr::mutate(district = as.character(district)) |>
  dplyr::arrange(district)

cat(sprintf("OGD total buildings: %d across %d districts\n",
            sum(ogd_by_district$n_ogd), nrow(ogd_by_district)))

# --- Step 7: Merge and compute ratio ---
comparison <- dplyr::full_join(
  ogd_by_district,
  osm_by_district,
  by = "district"
) |>
  dplyr::mutate(
    n_ogd = tidyr::replace_na(n_ogd, 0L),
    n_osm = tidyr::replace_na(n_osm, 0L),
    ratio_osm_to_ogd = round(n_osm / pmax(n_ogd, 1L), 2),
    is_focus = district %in% c("20", "21")
  ) |>
  dplyr::arrange(desc(is_focus), desc(ratio_osm_to_ogd))

cat("\n=== COMPARISON TABLE ===\n")
print(comparison, n = Inf)

write.csv(comparison, file.path(outdir, "coverage_by_district.csv"), row.names = FALSE)
cat("\nSaved coverage_by_district.csv\n")

# Summary statistics
cat(sprintf("\n=== SUMMARY ===\n"))
cat(sprintf("GEBAEUDEINFOOGD total: %d\n", sum(comparison$n_ogd, na.rm = TRUE)))
cat(sprintf("OSM total (in districts): %d\n", sum(comparison$n_osm, na.rm = TRUE)))
cat(sprintf("OSM total (all bbox): %d\n", osm_total))
cat(sprintf("Overall ratio OSM/OGD: %.2f\n",
            sum(comparison$n_osm) / max(sum(comparison$n_ogd), 1)))
cat(sprintf("Focus district 20 - OGD: %s  OSM: %s  ratio: %s\n",
            comparison$n_ogd[comparison$district == "20"],
            comparison$n_osm[comparison$district == "20"],
            comparison$ratio_osm_to_ogd[comparison$district == "20"]))
cat(sprintf("Focus district 21 - OGD: %s  OSM: %s  ratio: %s\n",
            comparison$n_ogd[comparison$district == "21"],
            comparison$n_osm[comparison$district == "21"],
            comparison$ratio_osm_to_ogd[comparison$district == "21"]))
