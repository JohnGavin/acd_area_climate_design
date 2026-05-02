#!/usr/bin/env Rscript
# Stage 2 OSM Analysis — saves intermediate RDS to avoid re-fetching
# Run from: Rscript /private/tmp/acd_stage2_osm/analysis/stage_2/stage2_osm_analysis.R

suppressPackageStartupMessages({
  library(osmdata)
  library(sf)
  library(dplyr)
  library(arrow)
  library(tibble)
  library(tidyr)
})

outdir <- "/private/tmp/acd_stage2_osm/analysis/stage_2"
cache_rds <- file.path(outdir, "osm_buildings_raw.rds")

vienna_bbox <- c(16.18, 48.12, 16.58, 48.32)

# --- Step 1: Fetch or load cached OSM data ---
if (file.exists(cache_rds)) {
  cat("Loading cached OSM data from", cache_rds, "\n")
  osm_buildings <- readRDS(cache_rds)
} else {
  cat("Fetching OSM buildings for Vienna bbox...\n")
  t0 <- proc.time()
  osm_buildings <- tryCatch(
    opq(bbox = vienna_bbox, timeout = 300) |>
      add_osm_feature(key = "building") |>
      osmdata_sf(quiet = FALSE),
    error = function(e) { cat("osmdata error:", conditionMessage(e), "\n"); NULL }
  )
  elapsed <- (proc.time() - t0)[["elapsed"]]
  cat(sprintf("Fetch elapsed: %.1f s\n", elapsed))
  if (is.null(osm_buildings)) { cat("FATAL: fetch failed\n"); quit(status=1) }
  saveRDS(osm_buildings, cache_rds)
  cat("Cached to", cache_rds, "\n")
}

poly_count       <- nrow(osm_buildings$osm_polygons)
multipoly_count  <- nrow(osm_buildings$osm_multipolygons)
osm_total        <- poly_count + multipoly_count
cat(sprintf("OSM polygons: %d  multipolygons: %d  total: %d\n",
            poly_count, multipoly_count, osm_total))

# Save summary
summary_df <- tibble::tibble(
  source          = "OSM",
  bbox            = paste(vienna_bbox, collapse = ","),
  n_polygons      = poly_count,
  n_multipolygons = multipoly_count,
  n_total         = osm_total,
  fetch_date      = as.character(Sys.Date())
)
write.csv(summary_df, file.path(outdir, "osm_total_summary.csv"), row.names = FALSE)

# --- Step 2: Load districts ---
districts_path <- "/private/tmp/acd_stage2_osm/inst/extdata/districts_2026-05-01.parquet"
districts_raw  <- arrow::read_parquet(districts_path)

# Detect geometry column
geom_col <- grep("(geom|_wkt)$", names(districts_raw), value = TRUE, ignore.case = TRUE)
if (length(geom_col) == 0) geom_col <- intersect(c("geometry"), names(districts_raw))
cat(sprintf("Districts geometry column: %s\n", geom_col[1]))

districts_sf <- sf::st_as_sf(districts_raw, wkt = geom_col[1], crs = 31287)

# Find district ID column
id_col <- intersect(c("BEZNR", "BEZ", "district", "BEZ_RZ"), names(districts_sf))[1]
cat(sprintf("District ID column: %s\n", id_col))
cat(sprintf("Districts: %d  Sample IDs: %s\n",
            nrow(districts_sf),
            paste(head(sort(districts_sf[[id_col]]), 5), collapse=",")))

# --- Step 3: Centroids of OSM buildings ---
cat("\nBuilding combined sf object...\n")
# Use only osm_id + geometry
poly_geom  <- osm_buildings$osm_polygons[, "osm_id", drop = FALSE]
multi_geom <- osm_buildings$osm_multipolygons[, "osm_id", drop = FALSE]

# Cast multipolygons to polygons for rbind
multi_cast <- sf::st_cast(multi_geom, "MULTIPOLYGON")

# simple rbind since both are sf with same column
osm_all <- rbind(
  poly_geom,
  multi_cast
)
cat(sprintf("Combined: %d features\n", nrow(osm_all)))

cat("Reprojecting to EPSG:31287...\n")
osm_31287 <- sf::st_transform(osm_all, 31287)

cat("Computing centroids (point_on_surface)...\n")
osm_centroids <- suppressWarnings(sf::st_point_on_surface(osm_31287))

# --- Step 4: Spatial intersect ---
cat("Intersecting centroids with districts...\n")
districts_31287 <- sf::st_transform(districts_sf, 31287)
hits <- sf::st_intersects(osm_centroids, districts_31287, sparse = TRUE)

osm_district <- vapply(hits, function(idx) {
  if (length(idx) == 0L) NA_character_
  else as.character(districts_31287[[id_col]][idx[1L]])
}, character(1L))

n_matched   <- sum(!is.na(osm_district))
n_unmatched <- sum( is.na(osm_district))
cat(sprintf("Matched: %d  Unmatched: %d\n", n_matched, n_unmatched))

# --- Step 5: Count by district ---
osm_by_district <- tibble::tibble(district = osm_district) |>
  dplyr::filter(!is.na(district)) |>
  dplyr::count(district, name = "n_osm") |>
  dplyr::arrange(district)

write.csv(osm_by_district, file.path(outdir, "osm_by_district.csv"), row.names = FALSE)
cat("Saved osm_by_district.csv\n")

# --- Step 6: Load OGD counts ---
joined_raw    <- arrow::read_parquet("/private/tmp/acd_stage2_osm/inst/extdata/joined_2026-05-01.parquet")
dist_col_ogd  <- intersect(c("district", "BEZNR", "BEZ", "GEB_BEZIRK"), names(joined_raw))[1]
cat(sprintf("OGD district column: %s\n", dist_col_ogd))

ogd_by_district <- joined_raw |>
  dplyr::count(.data[[dist_col_ogd]], name = "n_ogd") |>
  dplyr::rename(district = .data[[dist_col_ogd]]) |>
  dplyr::mutate(district = as.character(district))

cat(sprintf("OGD total: %d in %d districts\n", sum(ogd_by_district$n_ogd), nrow(ogd_by_district)))

# --- Step 7: Merge + ratio ---
comparison <- dplyr::full_join(ogd_by_district, osm_by_district, by = "district") |>
  dplyr::mutate(
    n_ogd            = tidyr::replace_na(n_ogd, 0L),
    n_osm            = tidyr::replace_na(n_osm, 0L),
    ratio_osm_to_ogd = round(n_osm / pmax(n_ogd, 1L), 2),
    is_focus         = district %in% c("20", "21")
  ) |>
  dplyr::arrange(desc(is_focus), desc(ratio_osm_to_ogd))

cat("\n=== COMPARISON TABLE ===\n")
print(comparison, n = Inf)

write.csv(comparison, file.path(outdir, "coverage_by_district.csv"), row.names = FALSE)
cat("\nSaved coverage_by_district.csv\n")

cat("\n=== KEY METRICS ===\n")
cat(sprintf("GEBAEUDEINFOOGD total: %d\n",   sum(comparison$n_ogd, na.rm=TRUE)))
cat(sprintf("OSM in-districts total: %d\n",   sum(comparison$n_osm, na.rm=TRUE)))
cat(sprintf("OSM full-bbox total: %d\n",       osm_total))
cat(sprintf("Overall ratio OSM/OGD: %.2f\n",
            round(sum(comparison$n_osm) / max(sum(comparison$n_ogd), 1), 2)))

for (d in c("20", "21")) {
  r <- comparison[comparison$district == d, ]
  if (nrow(r) > 0) {
    cat(sprintf("District %s: OGD=%d  OSM=%d  ratio=%.2f\n",
                d, r$n_ogd, r$n_osm, r$ratio_osm_to_ogd))
  }
}
