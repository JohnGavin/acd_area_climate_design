#!/usr/bin/env Rscript
# Continue from where OSM pull left off — districts + comparison
# Run after pull_osm_buildings.R already saved osm_by_district.csv

suppressPackageStartupMessages({
  library(sf)
  library(dplyr)
  library(arrow)
  library(tibble)
  library(tidyr)
})

outdir <- "/private/tmp/acd_stage2_osm/analysis/stage_2"

# Load saved OSM counts
osm_by_district <- read.csv(file.path(outdir, "osm_by_district.csv"), stringsAsFactors = FALSE)
osm_summary     <- read.csv(file.path(outdir, "osm_total_summary.csv"), stringsAsFactors = FALSE)
osm_total       <- osm_summary$n_total[1]
cat(sprintf("OSM total (from saved): %d\n", osm_total))
cat(sprintf("OSM in districts: %d\n", sum(osm_by_district$n_osm)))

# Load OGD building counts from joined parquet
joined_path <- "/private/tmp/acd_stage2_osm/inst/extdata/joined_2026-05-01.parquet"
joined_raw  <- arrow::read_parquet(joined_path)
cat(sprintf("Joined parquet: %d rows\n", nrow(joined_raw)))
cat("Columns:", paste(names(joined_raw), collapse = ", "), "\n")

# Find district column
dist_col_joined <- intersect(c("district", "BEZNR", "BEZ", "GEB_BEZIRK"), names(joined_raw))[1]
cat(sprintf("District column in joined: %s\n", dist_col_joined))

ogd_by_district <- joined_raw |>
  dplyr::count(.data[[dist_col_joined]], name = "n_ogd") |>
  dplyr::rename(district = .data[[dist_col_joined]]) |>
  dplyr::mutate(district = as.character(district)) |>
  dplyr::arrange(district)

cat(sprintf("OGD total: %d across %d districts\n",
            sum(ogd_by_district$n_ogd), nrow(ogd_by_district)))

# Merge and compute ratio
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

# Summary
cat("\n=== KEY METRICS ===\n")
ogd_total <- sum(comparison$n_ogd, na.rm = TRUE)
osm_in_districts <- sum(comparison$n_osm, na.rm = TRUE)
overall_ratio <- round(osm_in_districts / max(ogd_total, 1), 2)
cat(sprintf("GEBAEUDEINFOOGD total: %d\n", ogd_total))
cat(sprintf("OSM in-districts total: %d\n", osm_in_districts))
cat(sprintf("OSM full-bbox total: %d\n", osm_total))
cat(sprintf("Overall ratio OSM/OGD: %.2f\n", overall_ratio))

focus_rows <- comparison[comparison$district %in% c("20", "21"), ]
for (i in seq_len(nrow(focus_rows))) {
  cat(sprintf("District %s: OGD=%d  OSM=%d  ratio=%.2f\n",
              focus_rows$district[i],
              focus_rows$n_ogd[i],
              focus_rows$n_osm[i],
              focus_rows$ratio_osm_to_ogd[i]))
}
