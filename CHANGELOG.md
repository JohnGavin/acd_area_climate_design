# Changelog

## 2026-05-04

### Completed

11 PRs merged today on the upload vignette:

| PR | Issue(s) | Summary |
|---|---|---|
| #54 | #28, #45 | Consolidation: Fix A QUALIFY-bug, UI tweaks, methodology split, dot-plot chart |
| #55 | #28, #45 | Unwind: single upload vignette, methodology as in-page tabset (corrected #54 over-split) |
| #56 | #46 (Tier 1) | QA snapshot regression on V3 CSV (2,039 rows), `R/upload_algorithm.R::run_upload_algorithm()` (5/6 JS steps) |
| #60 | #57 attempt 1 | Two-page panel-tabset (Upload + Methodology) with 6 step-tabs and real worked examples |
| #61 | #57 attempt 6 | Fenced-div panel-tabset syntax — heading-attribute `## Pages {.panel-tabset}` silently failed in Quarto 1.8.26; rendered 0 nav-tabs/0 role=tab |
| #64 | #62, #63 | Fixed Pandoc table-parse swallowing download-btn/results-table; added repo+SHA+build-time footer; embedded `upload_algorithm.R#L14` link |
| #65 | #62 | German methodology translation (machine-translated, banner flags this); 30 `data-lang="de"` blocks |
| #68 | #66, #67 | Click-toggle fullscreen chart; in-place "Download updated CSV" after REST; `match_quality = rest_api_fallback` distinct value |
| #72 | #69, #70, #71 | Y-axis `layout.padding.left=90` + `autoSkip:false`; replaced "Fix A + Fix B" jargon with "static-lookup steps"; added row 13 ("Klosterneub. Str. 5") to sample xlsx |
| #74 | #73 | Removed district chart entirely (435 lines deleted) — 12 removal gates + 2 regression gates pass on live URL |

Also: hidden site navbar on upload.html only (page-scoped CSS); WCAG 4.5:1 light-mode contrast pair for `.upload-page-prose`; removed arbitrary FONT_MAX=22 (now 96).

### Failed Approaches

- **Heading-attribute panel-tabset syntax** `## Pages {.panel-tabset}` silently produced flat scroll instead of tabs (Quarto 1.8.26). Fix: use fenced-div `::: {.panel-tabset}` everywhere — that's what works in this Quarto version. Logged in #57 attempt 6 history.
- **Pandoc table parser eats following content.** Embedding a real `<table id="...">` with `<thead>/<tr>` inside a `<details>` block inside a raw-HTML chunk causes Pandoc to parse it AND swallow ~28 lines after `</details>`. The "Don't know how to traverse TableBody" Lua warning is the visible symptom. Fix: replace embedded `<table>` with `<div role="table">` grid — Pandoc stops parsing.
- **Heading-attribute fragment links from rendered HTML** to fictitious URLs. The first methodology PR linked `upload_methodology.html` from the new tabset; user wanted ZERO references to anything outside the upload vignette. Fix: keep methodology as in-page tab, no cross-link.
- **Auto-detected dark mode + missing light-mode CSS = white-on-white.** `.upload-page-prose` had `font-size` but no `color` declaration in light mode. When user's OS had `prefers-color-scheme: dark`, body got `dark-mode` class → light-grey text inherited, but background didn't always cascade → white-on-white text. Fix: always pair explicit light-mode AND dark-mode `color`+`background` rules.
- **Squash-merge strips `Closes #N` keywords.** PRs #68, #72 had Closes-keywords but linked issues stayed open. Fix: manually `gh issue close` after merge, or put the keyword in PR body (which the merge UI uses) not just commit.
- **`grep -c` counts lines, not occurrences.** Initial live verification showed `role="tab"` = 2 (lines) when actual count was 8 (occurrences). All multi-tab matches were on one line. Fix: `grep -oE pattern | wc -l`.
- **Build-time SHA in footer ≠ post-merge SHA.** R chunk reads `git rev-parse HEAD` at render time, producing the parent SHA. After squash-merge the live link points one commit behind. Acceptable for now; future: use `GITHUB_SHA` env var in CI render.
- **Footer chunk was wrong.** Agent put it INSIDE the panel-tabset close, hiding the footer behind a tab. Fix: footer chunk MUST be after final `:::` close.
- **Cleveland dot plot effort wasted.** Multiple PRs (#61 chart, #68 fullscreen, #72 y-axis padding) tried to fix the chart; user concluded "that was a disaster" and asked for total removal. Lesson: when a UI element keeps regressing after 3 fixes, propose deletion not iteration.
- **Methodology was authored EN-only by an agent.** Agent built per-step tabsets but didn't know to provide both languages; toggle silently failed for that page. Fix: bilingual scaffolding in agent prompts when site has language toggle.

### Accuracy / Metrics

- Match-rate: still 94.2% baseline (Fix A + B) + REST fallback; chart removal didn't change algorithm
- Snapshot test: 2 PASS, 1 SKIP (Tier-2 gold-standard) on V3 CSV — `tests/testthat/_snaps/upload-algorithm-snapshot.md` 144 KB
- Live URL passes 14 verification gates (12 chart-removal + 2 regression)
- Page weight: -435 lines after #74 chart removal

### Known Limitations

- **#58 (open):** QA Tier-2 gold-standard (~30-45 hand-verified rows from V3) not yet curated. Snapshot covers regression but not correctness.
- **#59 (open):** `upload-internals.html` should eventually be deleted once user confirms the archived Performance/Page-weight/Compatibility content is no longer needed.
- **Methodology DE translation** is machine-generated. Banner flags this; native review pending.
- **Footer SHA staleness:** clicked SHA points to parent commit, not post-merge SHA. Use CI render with `GITHUB_SHA` to fix properly.
- **Untracked artifacts** in working tree: `analysis/qa/deploy_validation_2026-05-03.md`, `docs/data/osm_coverage_by_district.csv`, `docs/data/osm_total_summary.csv` — provenance unclear from this session, left untouched.

### Process notes

- 6 attempts to land #57 (upload vignette structure) before correct two-page interpretation matched user intent. Lesson: explicit "tabulate intent vs delivered" before the first attempt avoids burning rounds.
- All agent runs this session were sonnet (no Opus delegation) due to budget pressure (CRITICAL $698/$500 at session start).
- All PRs included verification-gate `<fill>` placeholders that the agent populated before pushing — this caught Pandoc-table-parse silent failures that would otherwise have shipped.

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
