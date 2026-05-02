# Changelog

## 2026-05-02

### Completed
- **Phase 4 fully closed.** Stage 0 falsified the cross-validation premise (ACD is a building registry ID, not a zone reference). Stage 1a + 3 + Phase 3 (#21) replaced the broken `acd_agreement` factor with a distance-based `confidence_tier` (A/B/C/D/E). Stage 4 (#22) added a per-zone drilldown card with WUKSEA-GIS verification links. Stage 2 (#24) confirmed via OSM that GEBAEUDEINFOOGD covers ~19% of Vienna's actual building stock (5.3× undercount). Stage 5 (#25) shipped a methodology vignette synthesising the project.
- **HTML validation script** (#30, PR #31): `acd::validate_deploy()` using rvest + httr2 fetches every gh-pages URL and verifies HTTP status, error markers, broken assets, empty leaflets, empty tables, broken hash links. Found and fixed three of its own false-positive bugs during baselining (gregexpr -1 sentinel, relative-URL resolution, prose-pattern overlap). Caught a real fourth bug (case-sensitive marker regex) on first production use.
- **ACD ↔ address lookup page** (#28, PR #32): standalone Quarto page with crosstalk-wired DT + Leaflet, 4 filters (district, tier, year-built slider, zone), virtual-rendered 58k rows via DT Scroller, CSV download. Site-wide live URL at /vignettes/articles/lookup.html.
- **Dashboard fixes (PR #29):** building popups always showing district info (cause: district overlay added LAST, intercepting clicks; fix: pathOptions(interactive=FALSE)). Page 4 tabs with empty leaflets (cause: full Vienna has 0 in some link_status categories; fix: empty-state guards). Hex-code labels showing as cell text (cause: color column carried hex strings as data; fix: blank Color cells, drop the column on Page 6 link-status table).
- **Methodology vignette CSS 404 fix:** library(readr) bug (not in nix shell), hardcoded /private/tmp/... path, single-file render hash mismatch. Resolved by full-site `quarto render` and replacing readr with utils::read.csv. Side effect: full render strips docs/data/*.parquet — restored from HEAD.
- **3 global-rule amendments** in `~/docs_gh/llm/.claude/rules/`:
  - `orchestrator-protocol.md` — mandatory background-agent activity-timeout rule (15-min idle → intervene; 30-min hard cap; combined process+filesystem signal). Tightened from earlier 20-min draft after observing actual completion times of 12-13 min.
  - `nix-agent-shell-protocol.md` — worktree-isolated rix regenerations must use `(cd <worktree> && ...)` subshell or `setwd()` to avoid overwriting orchestrator's default.nix (root cause of #23, recurred once during Stage 2).
- **Live URL set:** index, dashboard, methodology, lookup — all PASS validator.

### Major findings logged
- ACD field is the building's own Adress-Code / Gebäudekennzahl (`analysis/stage_0/REPORT.md`), 6-digit zero-padded, range 1–232,762, unique per building.
- 27.9% of Vienna buildings (16,246 of 58,255) fall within an Energieraumplan zone.
- GEBAEUDEINFOOGD covers ~19% of OSM's 307,715 buildings — disclosed via dashboard card and methodology.

### Failed approaches / lessons
- First attempt at Page 3 vertical spacing (PR #21) — claimed done but architecturally constrained by panel-tabset cap. Closed #16 as wontfix.
- Stage 1a+3 dashboard agent (Agent B) stalled mid-task at ~20 min. Orchestrator took over and finished render + commit; agent's late completion notification arrived after merge with an orphaned commit on a deleted branch. No data loss; rule amended to mandate intervention earlier.
- Stage 2 OSM agent regenerated default.nix in the wrong checkout (rix `project_path = "."` resolved to orchestrator's main, not its worktree). Stripped udunits + shellHook patches. Restored from HEAD; rule amended to mandate `(cd <worktree> && ...)` subshell pattern.
- Validator's own initial bugs (gregexpr -1 sentinel, asset URL resolution against site root, prose-pattern overlap) were caught when baselining flagged "all FAIL" with implausibly uniform marker counts. Fixed before any deploy regressed.
- Quarto full-site render strips docs/data/*.parquet — open as #26.

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
- Initial layer name guesses (`ENERGIEPLANERPOGD`, `GEBAEUDEOGD`) — wrong; corrected via GetCapabilities to `ENERGIERAUMPLANOGD`, `GEBAEUDEINFOOGD`. Lesson: always verify WFS layer names before writing fetch code.
- Initial column assumptions (`ERPTYP`, `ERPRECHTSTAT`, `HOEHE`, `ADRESSE`) — none exist. The `dplyr::any_of()` rename guard prevented runtime errors but produced silently un-renamed columns. Real schema documented in STUBS.md.
- Subagent prompt suggesting `dplyr::tbl(con, sql("SELECT..."))` for remote DuckDB — flagged by user as raw-SQL violation per `~/docs_gh/llm/.claude/rules/duckdplyr-not-sql.md` lines 38-40. Replaced with `duckplyr::read_parquet_duckdb()`.

### Session end (2026-05-01)
- Initial commit pushed to https://github.com/JohnGavin/acd_area_climate_design (public, branch `main`)
- 6 follow-up issues filed (#1–#6) covering: schema alignment, ACD-agreement dashboard tab, default.nix regen, smoke-fetch, stage-2 remote storage, ctx_audit
- 1 upstream issue filed: JohnGavin/llm#97 (noisy session_stop.sh hook)

### Known limitations
- No live data committed yet — dashboard renders against synthetic placeholder
- Code uses pre-verification column names; behaviour is graceful (any_of guards) but rename map needs update (#1)
- Tests are synthetic only — no smoke test against real WFS yet (#4)
- default.nix copied from maps template; not regenerated for this project's deps (#3)
- ctx files for new dependencies (httr2, cli, digest, tibble, duckplyr) not yet generated (#6)

### Accuracy / Metrics
- Files committed: 29
- R/ source files: 6 (snapshot, fetch_acd_zones, fetch_buildings, join_buildings_zones, missing_data_cases, load_data)
- Test files: 2 (test-join.R 270 lines, test-placeholder.R)
- Dashboard: 1533 lines, 6 pages, 8-tab missing-link panel, 5-story tabset
- Dependencies declared: 9 Imports (sf, dplyr, rlang, glue, fs, httr2, cli, digest, tibble), 11 Suggests
- Tests not yet run (Nix shell regen pending #3) — will report PASS counts after smoke test
