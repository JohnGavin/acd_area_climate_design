# Current Work

## Status (2026-05-02)

**Phase 4 closed.** Dashboard, methodology, lookup pages live and PASS the validator. Open issues: post-render hook (#26) and the Page 3 joined-map empty-rendering investigation (#27).

## Live URLs (all PASS as of 2026-05-02)

- Site: https://johngavin.github.io/acd_area_climate_design/
- Dashboard: https://johngavin.github.io/acd_area_climate_design/vignettes/articles/dashboard.html
- Methodology: https://johngavin.github.io/acd_area_climate_design/vignettes/articles/methodology.html
- **Lookup (new):** https://johngavin.github.io/acd_area_climate_design/vignettes/articles/lookup.html
- Repo: https://github.com/JohnGavin/acd_area_climate_design

## What works

- Spatial join via `acd::join_buildings_zones()` with 6-state `link_status` enum
- Distance-based `confidence_tier` (A/B/C/D/E) replacing the broken `acd_agreement` premise
- Districts layer (`BEZIRKSGRENZEOGD`, 23 polygons) overlaid on every leaflet, focus 20 + 21 in bright yellow
- OSM coverage card on Page 2 (5.3× undercount disclosed)
- Per-zone drilldown card on Page 6 with WUKSEA-GIS verification links
- ACD↔address lookup page with crosstalk-wired DT + Leaflet, 58k rows, CSV download
- Dark theme on every leaflet (CartoDB.DarkMatter, link_status palette tuned)
- Stage-2 storage: docs/data/*.parquet served by Pages, accessible via `acd::load_acd_data(source = "remote")` using `duckplyr::read_parquet_duckdb()` (no raw SQL)
- Validator: `acd::validate_deploy()` checks every page on the gh-pages site

## Open issues

| # | Title | Status |
|---|---|---|
| 8 | Closeread English vignette | Open — narrative artifact |
| 20 | German scrollytelling | Open — narrative artifact |
| 26 | Post-render hook for docs/data/ | **Next** |
| 27 | Empty Page 3 joined map (validator passes — likely a runtime/JS issue) | **Next** |

## Architecture (current)

- `R/snapshot.R` — constants
- `R/fetch_acd_zones.R`, `R/fetch_buildings.R`, `R/fetch_districts.R` — paginated WFS fetch
- `R/join_buildings_zones.R` — spatial join + link_status + nearest_zone_dist_m + confidence_tier
- `R/missing_data_cases.R` — per-case helpers + dark-theme palette + tier helpers
- `R/load_data.R` — local/remote dispatcher (duckplyr remote)
- `R/validate_deploy.R` — gh-pages HTML structural validator
- `vignettes/articles/dashboard.qmd` — 6-page dashboard (~57 MB rendered)
- `vignettes/articles/methodology.qmd` — technical writeup
- `vignettes/articles/lookup.qmd` — DT + crosstalk + Leaflet search page
- `inst/extdata/{zones,buildings,districts,joined,osm_coverage_by_district,osm_total_summary}.{parquet,csv}` — committed snapshots
- `docs/` — full Quarto website (gh-pages root)
- `analysis/{stage_0,stage_2,qa,rationale}` — investigation outputs

## Decisions log (`analysis/rationale/DECISIONS.md`)

1. Snapshot pinning by date (2026-05-01)
2. Centroid-based spatial join (POC)
3. `link_status` 6-state enum
4. ~~`acd_agreement`~~ → `confidence_tier` (A/B/C/D/E based on distance)
5. Storage tier 1 = inst/extdata; tier 2 = docs/data (duckplyr remote)
6. Focus districts: 20 (Brigittenau), 21 (Floridsdorf)
7. Distance-based tiers replace cross-validation premise (Stage 0 finding)
8. Keep GEBAEUDEINFOOGD primary; defer GEBAEUDETYPOGD swap (lacks BAUJAHR/GESCH_ANZ/BEZ); supplement with OSM for coverage stats
9. Empty Page 4 tabs render as info messages, not blank tiles
10. District overlays are non-interactive (clicks pass through to buildings/zones)
11. Color columns in gt tables: blank cell text or dropped (cell_fill provides the visual)
12. Validator pattern set: `MISSING EVIDENCE`, `not found in targets`, `Error in \``, `#> NULL` (specific shapes; dropped overly-generic `Error in` and `not available`)

## How a new Claude picks up

1. Read this file + `analysis/stage_0/REPORT.md` + CHANGELOG.md + STUBS.md
2. `gh issue list --state open` and `gh pr list`
3. `acd::validate_deploy()` for current health check
4. Branch off main; commit incrementally; PR/merge per usual
5. Per the orchestrator-protocol: agents that regenerate default.nix MUST use `(cd <worktree> && ...)` subshell — DO NOT clobber the main checkout's nix file. The udunits + shellHook patches are critical.

## Burn-rate awareness

CRITICAL at session start ($380/$500). All execution agents this session were sonnet. Rule amendments captured for the next session.
