# Changelog

## 2026-05-01

### Completed
- Initialized R package skeleton: DESCRIPTION, LICENSE, .gitignore, .Rprofile, default.R, default.nix
- Templated from `/Users/johngavin/docs_gh/proj/data/maps/` (preserves udunits overlay + R_LIBS_SITE shellHook)
- Created STUBS.md with shared conventions for parallel work
- Dispatched parallel agents: skeleton (haiku), fetch + join (sonnet), dashboard (sonnet) — all completed
- R/fetch_acd_zones.R, R/fetch_buildings.R, R/join_buildings_zones.R, R/missing_data_cases.R written (cache-first WFS fetch, centroid-based join, 6-state link_status enum, all helpers)
- tests/testthat/test-join.R written (5 test blocks, all synthetic, zero network)
- vignettes/articles/dashboard.qmd written (1533 lines, 6 pages including 8-tab missing-link panel and stories tabset)
- Added httr2, cli, digest, tibble, duckplyr to DESCRIPTION Imports
- CHARTER.md added (per project-charter rule) — question, deliverable, "done", out-of-scope, scope-creep tripwires
- R/load_data.R added — single entry point with source = c("local", "remote"); remote uses duckplyr::read_parquet_duckdb() (zero raw SQL per duckdplyr-not-sql rule)
- REMOTE_BASE_URL added to R/snapshot.R pointing at GitHub Pages docs/data/
- Filed JohnGavin/llm#97 to track the noisy "Stop hook error: Failed with non-blocking status code" emitted by session_stop.sh

### In Progress
(nothing — all dispatched parallel work complete)

### Pending
- Generate default.nix via rix (Rscript default.R) and re-apply udunits + shellHook patches
- ctx_audit DESCRIPTION (httr2/cli/digest/tibble/duckplyr added — may need ctx_sync)
- Verify WFS column name assumptions via DescribeFeatureType (BAUJAHR, HOEHE, ADRESSE, ERPTYP, ERPRECHTSTAT)
- Smoke-test fetch with max_features=100 (zones), 500 (buildings) — ~2.5 MB, ~15 s
- Render dashboard locally
- git init + push to GitHub (JohnGavin/acd_area_climate_design, public)

### Major findings (live WFS schema verification, 2026-05-01)
- **Layer names corrected via GetCapabilities.** Assumed `ENERGIEPLANERPOGD` and `GEBAEUDEOGD`; actual are `ENERGIERAUMPLANOGD` and `GEBAEUDEINFOOGD`. Updated `R/snapshot.R` and `STUBS.md`.
- **The buildings layer (`GEBAEUDEINFOOGD`) has a pre-populated `ACD` column.** The City of Vienna already labels each building with its ACD designation. This reframes the project from "compute the link via spatial join" to "**cross-validate the pre-linked ACD against an independent spatial join**". Much stronger POC story: we can quantify agreement, find disagreements, and flag suspect classifications.
- **The zones layer has `GEBID` (building ID) and `BEZNR` (district number).** Zones already claim which buildings they cover. This gives us a third linkage to compare: spatial join vs. building-side ACD vs. zone-side GEBID.
- **No `ERPTYP`/`ERPRECHTSTAT`/`HOEHE`/`ADRESSE` fields exist.** Zone type/legal status must be inferred from `ERPLABEL` parsing or `WEBLINK_VO`. Building height proxied via `GESCH_ANZ` (story count). Address composed from `STRNAML` + `VONA` + `VONN`.
- Added new `acd_agreement` factor column to joined schema: `spatial=acd_native` / `mismatch` / `spatial_only` / `acd_only` / `neither`. This becomes a 7th tab on the missing-link page.

### Architecture decisions
- Snapshot-pinned by date (`SNAPSHOT_DATE <- "2026-05-01"`) for reproducibility
- Spatial join via centroid + st_within for POC; area-weighted overlap deferred
- Storage tier 1: inst/extdata Parquet (~30 MB committed). Tier 2 (GitHub Pages + DuckDB httpfs via duckplyr::read_parquet_duckdb) wired into R/load_data.R as `source = "remote"` — flip to enable. Tier 3 (HF Datasets / S3) deferred.
- Vienna-only POC; Austria extension sources documented (BEV cadastre, Statistik Austria, INSPIRE AT, GeoSphere, Eurostat GISCO, OSM) — deferred

### Failed Approaches
(none yet)
