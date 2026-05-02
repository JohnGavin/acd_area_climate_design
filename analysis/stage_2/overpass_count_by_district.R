#!/usr/bin/env Rscript
# Use Overpass API directly via httr2 to get building counts per Vienna district
# Much lighter than osmdata full geometry pull

suppressPackageStartupMessages({
  library(httr2)
  library(dplyr)
  library(arrow)
  library(tibble)
  library(tidyr)
  library(sf)
})

outdir <- "/private/tmp/acd_stage2_osm/analysis/stage_2"

# Vienna district bounding boxes (approximate, for splitting queries)
# District numbers 1-23

# --- Option A: Count buildings per named district using Overpass area query ---
# Use the Wien districts from OSM which have name:de tags
# Each Viennese district is "Wien X. Bezirk" or "Wien, X. Bezirk"

overpass_count_district <- function(district_num) {
  # Vienna districts in OSM have admin_level=9 and the relation carries
  # the district number as a tag. Use area-based query.
  # Template: count buildings within the named district
  query <- sprintf(
    '[out:json][timeout:60];
area["admin_level"="9"]["name"~"^%s[\\\\. ]", i]["boundary"="administrative"]->.d;
(
  way["building"](area.d);
  relation["building"](area.d);
);
out count;',
    as.character(district_num)
  )

  resp <- tryCatch({
    request("https://overpass-api.de/api/interpreter") |>
      req_body_form(data = query) |>
      req_timeout(90) |>
      req_retry(max_tries = 2, backoff = ~ 10) |>
      req_perform()
  }, error = function(e) { NULL })

  if (is.null(resp)) return(NA_integer_)

  body <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (is.null(body)) return(NA_integer_)

  # Count is in body$elements[[1]]$tags$total
  elements <- body$elements
  if (length(elements) == 0) return(0L)

  tags <- elements[[1]]$tags
  as.integer(tags$total %||% 0L)
}

`%||%` <- function(x, y) if (!is.null(x)) x else y

# --- Alternative: Use bounding box per district from the districts parquet ---
cat("Loading districts layer...\n")
districts_raw <- arrow::read_parquet(
  "/private/tmp/acd_stage2_osm/inst/extdata/districts_2026-05-01.parquet"
)
geom_col <- grep("(geom|_wkt)$", names(districts_raw), value = TRUE, ignore.case = TRUE)[1]
districts_sf <- sf::st_as_sf(districts_raw, wkt = geom_col, crs = 31287)
id_col <- intersect(c("BEZNR", "BEZ", "district"), names(districts_sf))[1]
cat(sprintf("District ID col: %s, n=%d\n", id_col, nrow(districts_sf)))

# Transform to WGS84 for bbox
districts_wgs84 <- sf::st_transform(districts_sf, 4326)

# For each district, get bbox and query Overpass for count
overpass_count_bbox <- function(bbox_vec, timeout_s = 60) {
  # bbox_vec: c(lat_min, lon_min, lat_max, lon_max) — Overpass format
  query <- sprintf(
    '[out:json][timeout:%d];
(
  way["building"](%s);
  relation["building"](%s);
);
out count;',
    timeout_s,
    paste(bbox_vec, collapse = ","),
    paste(bbox_vec, collapse = ",")
  )

  resp <- tryCatch({
    request("https://overpass-api.de/api/interpreter") |>
      req_body_form(data = query) |>
      req_timeout(timeout_s + 30) |>
      req_retry(max_tries = 2, backoff = ~ 15) |>
      req_perform()
  }, error = function(e) {
    cat("  Error:", conditionMessage(e), "\n")
    NULL
  })

  if (is.null(resp)) return(NA_integer_)
  body <- tryCatch(resp_body_json(resp), error = function(e) NULL)
  if (is.null(body)) return(NA_integer_)
  elements <- body$elements
  if (length(elements) == 0) return(0L)
  tags <- elements[[1]]$tags
  as.integer(tags[["total"]] %||% 0L)
}

# Query each district with its bbox
cat("\nQuerying Overpass for building counts per district...\n")
cat("(Note: bbox counts include buildings in district bbox, may overlap borders)\n\n")

results <- vector("list", nrow(districts_wgs84))
for (i in seq_len(nrow(districts_wgs84))) {
  dist_id <- as.character(districts_wgs84[[id_col]][i])
  bbox_sf  <- sf::st_bbox(districts_wgs84[i, ])
  # Overpass format: lat_min, lon_min, lat_max, lon_max
  bbox_vec <- round(c(bbox_sf["ymin"], bbox_sf["xmin"],
                      bbox_sf["ymax"], bbox_sf["xmax"]), 5)

  cat(sprintf("District %s [%d/%d]: bbox %.4f,%.4f,%.4f,%.4f ... ",
              dist_id, i, nrow(districts_wgs84),
              bbox_vec[1], bbox_vec[2], bbox_vec[3], bbox_vec[4]))

  n <- overpass_count_bbox(bbox_vec)
  cat(sprintf("%s\n", if (is.na(n)) "FAILED" else as.character(n)))
  results[[i]] <- tibble::tibble(district = dist_id, n_osm_bbox = n)

  # Small delay between requests
  Sys.sleep(2)
}

osm_by_district_bbox <- dplyr::bind_rows(results)
write.csv(osm_by_district_bbox, file.path(outdir, "osm_by_district_bbox.csv"), row.names = FALSE)
cat("\nSaved osm_by_district_bbox.csv\n")

# Load OGD counts
joined_raw   <- arrow::read_parquet("/private/tmp/acd_stage2_osm/inst/extdata/joined_2026-05-01.parquet")
dist_col_ogd <- intersect(c("district", "BEZNR", "BEZ", "GEB_BEZIRK"), names(joined_raw))[1]

ogd_by_district <- joined_raw |>
  dplyr::count(.data[[dist_col_ogd]], name = "n_ogd") |>
  dplyr::rename(district = .data[[dist_col_ogd]]) |>
  dplyr::mutate(district = as.character(district))

cat(sprintf("OGD total: %d\n", sum(ogd_by_district$n_ogd)))

# Merge
comparison_bbox <- dplyr::full_join(
  ogd_by_district,
  osm_by_district_bbox,
  by = "district"
) |>
  dplyr::mutate(
    n_ogd       = tidyr::replace_na(n_ogd, 0L),
    n_osm_bbox  = tidyr::replace_na(n_osm_bbox, 0L),
    ratio       = round(n_osm_bbox / pmax(n_ogd, 1L), 2),
    is_focus    = district %in% c("20", "21")
  ) |>
  dplyr::arrange(desc(is_focus), desc(ratio))

cat("\n=== BBOX COMPARISON ===\n")
print(comparison_bbox, n = Inf)
write.csv(comparison_bbox, file.path(outdir, "comparison_bbox.csv"), row.names = FALSE)
cat("Saved comparison_bbox.csv\n")

# Summary
osm_summary <- read.csv(file.path(outdir, "osm_total_summary.csv"))
cat(sprintf("\nOSM total (bbox full Vienna, from prior run): %d\n", osm_summary$n_total))
cat(sprintf("OGD total (GEBAEUDEINFOOGD): %d\n", sum(comparison_bbox$n_ogd, na.rm=TRUE)))
