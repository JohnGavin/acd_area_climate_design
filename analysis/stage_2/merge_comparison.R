#!/usr/bin/env Rscript
# Fix district ID alignment and produce final coverage_by_district.csv

suppressPackageStartupMessages({
  library(dplyr)
  library(arrow)
  library(tibble)
  library(tidyr)
})

outdir <- "/private/tmp/acd_stage2_osm/analysis/stage_2"

# Load OSM bbox counts (district IDs like "1", "2", ... "23")
osm_bbox <- read.csv(file.path(outdir, "osm_by_district_bbox.csv"), stringsAsFactors = FALSE)
# Normalise to zero-padded 2-digit
osm_bbox <- osm_bbox |>
  dplyr::mutate(district = sprintf("%02d", as.integer(district))) |>
  dplyr::rename(n_osm = n_osm_bbox)

cat("OSM districts:\n")
print(osm_bbox)

# Load OGD counts from joined parquet
joined_raw   <- arrow::read_parquet("/private/tmp/acd_stage2_osm/inst/extdata/joined_2026-05-01.parquet")
dist_col_ogd <- intersect(c("district", "BEZNR", "BEZ", "GEB_BEZIRK"), names(joined_raw))[1]
cat(sprintf("\nOGD district column: %s\n", dist_col_ogd))
cat("Sample values:", paste(head(sort(unique(joined_raw[[dist_col_ogd]]))), collapse=", "), "\n")

ogd_by_district <- joined_raw |>
  dplyr::count(.data[[dist_col_ogd]], name = "n_ogd") |>
  dplyr::rename(district = .data[[dist_col_ogd]]) |>
  dplyr::mutate(district = sprintf("%02d", as.integer(as.character(district)))) |>
  dplyr::arrange(district)

cat(sprintf("\nOGD by district (%d districts, total=%d):\n",
            nrow(ogd_by_district), sum(ogd_by_district$n_ogd)))
print(ogd_by_district)

# Merge on normalised district IDs
comparison <- dplyr::full_join(ogd_by_district, osm_bbox, by = "district") |>
  dplyr::mutate(
    n_ogd            = tidyr::replace_na(n_ogd, 0L),
    n_osm            = tidyr::replace_na(n_osm, 0L),
    ratio_osm_to_ogd = round(n_osm / pmax(n_ogd, 1L), 2),
    is_focus         = district %in% c("20", "21")
  ) |>
  dplyr::arrange(desc(is_focus), desc(ratio_osm_to_ogd))

# Add district names
district_names <- c(
  "01" = "Innere Stadt",    "02" = "Leopoldstadt",   "03" = "Landstrasse",
  "04" = "Wieden",          "05" = "Margareten",      "06" = "Mariahilf",
  "07" = "Neubau",          "08" = "Josefstadt",      "09" = "Alsergrund",
  "10" = "Favoriten",       "11" = "Simmering",       "12" = "Meidling",
  "13" = "Hietzing",        "14" = "Penzing",         "15" = "Rudolfsheim-Fuenfhaus",
  "16" = "Ottakring",       "17" = "Hernals",         "18" = "Waehring",
  "19" = "Doebling",        "20" = "Brigittenau",     "21" = "Floridsdorf",
  "22" = "Donaustadt",      "23" = "Liesing"
)
comparison <- comparison |>
  dplyr::mutate(district_name = district_names[district]) |>
  dplyr::select(district, district_name, n_ogd, n_osm, ratio_osm_to_ogd, is_focus)

cat("\n=== FINAL COMPARISON TABLE ===\n")
print(comparison, n = Inf)

write.csv(comparison, file.path(outdir, "coverage_by_district.csv"), row.names = FALSE)
cat("\nSaved coverage_by_district.csv\n")

# Top 5 by ratio (non-focus)
top5 <- comparison |>
  dplyr::filter(!is_focus) |>
  dplyr::slice_max(ratio_osm_to_ogd, n = 5)
cat("\nTop 5 districts by ratio_osm_to_ogd (non-focus):\n")
print(top5)

# Overall summary
osm_summary <- read.csv(file.path(outdir, "osm_total_summary.csv"))
osm_total   <- osm_summary$n_total[1]
ogd_total   <- sum(comparison$n_ogd, na.rm = TRUE)
osm_summed  <- sum(comparison$n_osm, na.rm = TRUE)

cat(sprintf("\n=== KEY METRICS ===\n"))
cat(sprintf("GEBAEUDEINFOOGD total:      %d\n", ogd_total))
cat(sprintf("OSM total (full Vienna bbox): %d\n", osm_total))
cat(sprintf("OSM summed (per-district bbox, with overlap): %d\n", osm_summed))
cat(sprintf("Overall OSM-bbox/OGD ratio: %.1fx\n", osm_total / max(ogd_total, 1)))

for (d in c("20", "21")) {
  r <- comparison[comparison$district == d, ]
  if (nrow(r) > 0) {
    cat(sprintf("District %s (%s): OGD=%d  OSM-bbox=%d  ratio=%.1fx\n",
                d, r$district_name, r$n_ogd, r$n_osm, r$ratio_osm_to_ogd))
  }
}
