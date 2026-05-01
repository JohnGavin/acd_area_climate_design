# Current Work

## Status (2026-05-01, end of session)

Full-Vienna data live (58,255 buildings, 416 zones). Cross-validation surfaces a 72% `acd_only` divergence that needs investigation. Visual rework + investigation kicked off in parallel.

## Live URLs

- Site: https://johngavin.github.io/acd_area_climate_design/
- Dashboard: https://johngavin.github.io/acd_area_climate_design/vignettes/articles/dashboard.html
- Repo: https://github.com/JohnGavin/acd_area_climate_design

## Active workstreams (parallel agents)

### Phase 2 (visual + layout + dark theme + captions) — sonnet agent in worktree
Branch: `feat/phase-2-visual-redesign` (worktree)
Touches: `vignettes/articles/dashboard.qmd`, `vignettes/articles/custom.scss`, `R/missing_data_cases.R`
Issues addressed: #12 (dark theme), #16 (Page 3 spacing), parts of #2 + remaining UX requests.

### Phase 4 Stage 0 (cross-validation sanity check) — sonnet r-debugger in worktree
Branch: `investigation/cross-validation-stage-0` (worktree)
Touches: `analysis/`, possibly `R/` for buffer experiments. Does NOT touch dashboard.qmd.
Issues addressed: #15 Stage 0 (buffer-tolerance test, ACD vs PLANNR check, sample acd_only inspection)

### Phase 3 (ACD redesign with drill-downs + confidence categories) — DEFERRED
Will start after Phase 2 lands. Drill-downs need the underlying confidence tiers, which come from Phase 4 Stage 3. So Phase 3 may end up bundled with Stage 3.

## Open issues (GitHub)

| # | Title | Phase |
|---|---|---|
| 8 | Closeread scrollytelling vignette | Later |
| 12 | Dark-theme all interactive maps | Phase 2 (in progress) |
| 14 | Investigate GEBAEUDEINFOOGD = 58k vs 220k | Phase 4 Stage 1 |
| 15 | Cross-validation deep dive (confidence-tiered) | Phase 4 (in progress, Stage 0) |
| 16 | Page 3 vertical spacing — second attempt, browser-verify | Phase 2 (in progress) |

## Architecture (current)

- `R/snapshot.R` — constants (SNAPSHOT_DATE, layer names, CRS)
- `R/fetch_acd_zones.R`, `R/fetch_buildings.R` — paginated WFS fetch
- `R/join_buildings_zones.R` — centroid-based spatial join + 6-state link_status enum + acd_agreement factor
- `R/missing_data_cases.R` — per-case helpers + `link_status_summary()` palette
- `R/load_data.R` — local/remote dispatcher (duckplyr for remote queries against GitHub Pages Parquet)
- `vignettes/articles/dashboard.qmd` — 6-page Quarto dashboard
- `inst/extdata/{zones,buildings,joined}_2026-05-01.parquet` — full Vienna snapshots (~7.7 MB total)
- `docs/data/*.parquet` — same files for HTTP serving via gh-pages
- `docs/vignettes/articles/dashboard.html` — rendered output

## What worked

- WFS pagination via `startIndex` + `count = 5000` (12 pages for full buildings layer)
- `dplyr::any_of()` rename guards survive WFS schema variations gracefully
- `acd_agreement` factor surfaces the city-vs-spatial divergence as a single column
- `R/load_data.R` with `source = "local"|"remote"` keeps the two storage tiers wire-compatible
- Burn-rate-aware delegation: every code-execution agent in this session has been sonnet, not opus
- The user's "list all asks before fixing" discipline caught a lot of redundant work

## What failed

- Initial layer name guesses (`ENERGIEPLANERPOGD`, `GEBAEUDEOGD`) — corrected via GetCapabilities
- Initial column assumptions (`ERPTYP`, `ERPRECHTSTAT`, `HOEHE`, `ADRESSE`) — none exist
- First attempt at Page 3 vertical spacing — claimed done but user found it still wrong (#16)
- Initial "220,000 buildings" estimate — actual layer returns 58,255 (#14)
- Subagent prompt suggesting `dplyr::tbl(con, sql("SELECT..."))` — flagged by user as raw-SQL violation (rule `duckdplyr-not-sql.md` lines 38-40)
- A subagent's `bldg_geom[[i]]` (sfg, no CRS) → bug, fixed to `bldg_geom[i]` (sfc, retains CRS)
- Synthetic placeholder fallback in dashboard hid real issues until full data exposed them
- Hardcoded values in prose ("220,000", "Vienna ACD: Building-Zone Linkage" title) — replaced with dynamic R per `dynamic-prose-values` rule

## Key findings (cross-validation, full data)

- agree_in_zone: 16,246 (27.9%)
- acd_only: 42,009 (72.1%) — **investigate**
- spatial_only: 0
- agree_no_zone: 0

The 0 `spatial_only` is interesting: the city's coverage is a strict superset of our spatial join. Whatever the spatial join finds, the city has also tagged. The disagreement is one-directional.

## Decisions (logged in analysis/rationale/DECISIONS.md)

1. Snapshot pinning by date (2026-05-01)
2. Centroid-based spatial join (not area-weighted) for POC
3. `link_status` 6-state enum as diagnostic
4. `acd_agreement` factor as cross-validation column
5. Storage tier 1 = `inst/extdata/`, tier 2 = `docs/data/` via duckplyr (no SQL)
6. Districts 20 (Brigittenau) + 21 (Floridsdorf) are the focus districts (user-stated 2026-05-01)

## How a new Claude picks up

1. Read this file + CHANGELOG.md + STUBS.md
2. Check open issues: `gh issue list --repo JohnGavin/acd_area_climate_design --state open`
3. Check open PRs: `gh pr list --repo JohnGavin/acd_area_climate_design`
4. Check active worktrees: `git -C /Users/johngavin/docs_gh/proj/finance/data/acd_area_climate_design worktree list`
5. The two parallel branches (`feat/phase-2-visual-redesign` and `investigation/cross-validation-stage-0`) may have unmerged work — check their status before starting new work
6. Continue with whichever phase the user asks for, or default to merging Phase 2 if it has landed

## Burn-rate awareness

CRITICAL at start of session ($380/$500). All execution agents are sonnet. Opus reserved for orchestration.

## Open user questions

(none currently — full plan approved 2026-05-01)
