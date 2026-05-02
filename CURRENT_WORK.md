# Current Work

## Status (2026-05-02)

**Phase 2 visual rework merged + live.** Stage 0 investigation **falsified the cross-validation premise** — the ACD field is the building's own registry ID, not a zone reference. Currently combining Stage 1a (districts layer) + Stage 3 (confidence_tier) + Phase 3 (dashboard rework) into a single PR.

## Live URLs

- Site: https://johngavin.github.io/acd_area_climate_design/
- Dashboard: https://johngavin.github.io/acd_area_climate_design/vignettes/articles/dashboard.html
- Repo: https://github.com/JohnGavin/acd_area_climate_design

## CRITICAL FINDING (Stage 0, 2026-05-02)

The `ACD` column on buildings is the building's own registry number (Adress-Code / Gebäudekennzahl), NOT a zone reference. Every building has a unique 6-digit ACD value (range 1 to 232,762). 0 string matches across PLANNR / ERPLABEL / OBJECTID / ID / GEBID.

**The `acd_agreement` factor we built is a category error.** Levels `agree_in_zone` (27.9%) and `acd_only` (72.1%) compare "is in spatial zone" vs "has a registry ID" (universal). The legitimate result is simpler: 27.9% of Vienna buildings fall within an Energieraumplan zone.

**Buffer sweep falsified CRS / boundary precision (H1):** 5m buffer adds only 184 buildings (0.3pp). Buildings outside zones are genuinely outside, not edge cases.

**Replacement design:** distance-based `confidence_tier` (A/B/C/D/E):
- A: inside zone, >5m from boundary (~26%)
- B: inside zone, ≤5m from boundary (~2%)
- C: outside, ≤25m from zone (~10%)
- D: outside, 25-500m from zone (~50%)
- E: outside, >500m from zone (~12%)

Full report: `analysis/stage_0/REPORT.md` on `main`.

## Active workstream

### Stage 1a + Stage 3 + Phase 3 (combined PR)
Branch: `feat/stage-1a-and-3` (worktree at `/private/tmp/acd_stage1a_3`)

Two sequential agents on the same branch:
1. **Agent A (in progress):** R-code only — fetch BEZIRKSGRENZEOGD (23 districts), drop acd_agreement, build confidence_tier, refresh joined Parquet, update tests. Sonnet general-purpose.
2. **Agent B (next):** Dashboard rework — replace acd_agreement cards with confidence tier visualizations, drill-downs, district 20+21 highlighting via the new districts layer. Sonnet general-purpose.

Then orchestrator opens PR + merges.

### GEBAEUDETYPOGD swap — DEFERRED
Research for #14 found GEBAEUDETYPOGD has 438k buildings (vs 58k for our current GEBAEUDEINFOOGD primary), but lacks BAUJAHR / GESCH_ANZ / BEZ — the rich attributes the dashboard depends on. Decision: keep GEBAEUDEINFOOGD primary, document the coverage limitation. Comment on #14: https://github.com/JohnGavin/acd_area_climate_design/issues/14#issuecomment-4361370443

## Open issues (GitHub)

| # | Title | Status |
|---|---|---|
| 2 | (closed in #11) | — |
| 8 | Closeread scrollytelling vignette | Later — needs full data |
| 12 | Dark-theme all interactive maps | ✅ landed in PR #18 |
| 14 | GEBAEUDEINFOOGD coverage (58k vs 220k) | Researched (see comment); switch deferred |
| 15 | Cross-validation deep dive | Stage 0 done (#19); Stages 1a+3 in progress; Stages 1b/2/4/5 open |
| 16 | Page 3 vertical spacing | Architecturally constrained (panel-tabset cap); commented |
| 17 | Phase 3: drill-downs + confidence categories | In progress (combined with Stage 1a) |

## Architecture (current on main)

- `R/snapshot.R` — constants (SNAPSHOT_DATE, layer names, CRS)
- `R/fetch_acd_zones.R`, `R/fetch_buildings.R` — paginated WFS fetch
- `R/join_buildings_zones.R` — spatial join + 6-state link_status + acd_agreement (BROKEN, being replaced)
- `R/missing_data_cases.R` — per-case helpers + dark-theme palette
- `R/load_data.R` — local/remote dispatcher (duckplyr remote)
- `vignettes/articles/dashboard.qmd` — 6 pages, 2.78 MB raw / 11.8 MB gzip on the wire (post-Phase 2)
- `inst/extdata/{zones,buildings,joined}_2026-05-01.parquet` — Vienna snapshots
- `docs/data/*.parquet` — HTTP-serving copies
- `analysis/stage_0/` — Stage 0 investigation outputs
- `analysis/rationale/DECISIONS.md` — forking-paths log

## What worked (cumulative)

- Two-agent parallelism via `git worktree add` — independent worktrees, clean merges
- WFS pagination via `startIndex` + `count = 5000` (12 pages for full buildings)
- `dplyr::any_of()` rename guards survive WFS schema variations
- Burn-rate-aware delegation: every code-execution agent has been sonnet, not opus
- "List all asks before fixing" discipline catches a lot of redundant work
- Stage 0 hypothesis-experiment-conclusion structure pinpointed the broken cross-validation premise quickly

## What failed (lessons)

- Initial layer name guesses (`ENERGIEPLANERPOGD`, `GEBAEUDEOGD`) — corrected via GetCapabilities
- Initial column assumptions (`ERPTYP`, `ERPRECHTSTAT`, `HOEHE`, `ADRESSE`) — none exist
- First Page 3 vertical spacing fix — claimed done but architecturally constrained by panel-tabset cap
- "220,000 buildings" estimate — actual GEBAEUDEINFOOGD layer is 58,255 (curated subset)
- Subagent suggesting `dplyr::tbl(con, sql("SELECT..."))` — flagged by user as raw-SQL violation (rule `duckdplyr-not-sql.md` line 38-40)
- `bldg_geom[[i]]` (sfg, no CRS) → bug, fixed to `bldg_geom[i]` (sfc retains CRS)
- Synthetic placeholder fallback hid real issues until full data exposed them
- **The cross-validation `acd_agreement` factor was conceptually broken from the start** — built on the assumption that ACD references zone membership, when it's actually a building registry ID. Stage 0 caught this. Lesson: validate the SEMANTICS of every field before building logic on it. Schema verification (`DescribeFeatureType`) tells you what columns exist; it doesn't tell you what they MEAN.
- Stage 0 agent hit rate limit before completing buffer sweep + REPORT synthesis — orchestrator finished both directly. Lesson: split long agent runs into smaller checkpointed phases.

## Decisions (logged in analysis/rationale/DECISIONS.md)

1. Snapshot pinning by date (2026-05-01)
2. Centroid-based spatial join (not area-weighted) for POC
3. `link_status` 6-state enum as diagnostic
4. ~~`acd_agreement` factor~~ — **broken, being replaced with `confidence_tier`** (Stage 0 finding)
5. Storage tier 1 = `inst/extdata/`, tier 2 = `docs/data/` via duckplyr (no SQL)
6. Districts 20 (Brigittenau) + 21 (Floridsdorf) are the focus districts
7. **2026-05-02:** Distance-based `confidence_tier` (A/B/C/D/E) replaces `acd_agreement`
8. **2026-05-02:** Keep GEBAEUDEINFOOGD primary; defer GEBAEUDETYPOGD swap (lacks BAUJAHR/GESCH_ANZ/BEZ)

## How a new Claude picks up

1. Read this file + `analysis/stage_0/REPORT.md` + CHANGELOG.md + STUBS.md
2. Check open issues: `gh issue list --repo JohnGavin/acd_area_climate_design --state open`
3. Check open PRs: `gh pr list --repo JohnGavin/acd_area_climate_design`
4. Check active worktrees: `git -C /Users/johngavin/docs_gh/proj/finance/data/acd_area_climate_design worktree list`
5. If `feat/stage-1a-and-3` worktree has uncommitted work, that's where the in-progress R refactor + dashboard rework lives.
6. The cross-validation logic is being replaced — anything referring to `acd_agreement` is legacy. The new contract is `confidence_tier` (A/B/C/D/E) based on distance to nearest zone boundary.

## Burn-rate awareness

CRITICAL at start of session ($380/$500). All execution agents are sonnet. Opus reserved for orchestration.

## Open user questions

(none currently)
