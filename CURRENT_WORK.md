# Current Work

## Status: POC structurally complete, schema-aligned, awaiting first commit + smoke fetch.

## Goal
End-to-end vignette displaying Vienna ACD zones + buildings + spatial join, with explicit handling of every missing-linkage case AND **cross-validation of the city's pre-linked `ACD` column against the independent spatial join**.

## Sources (verified 2026-05-01)
- WFS: `https://data.wien.gv.at/daten/geo` (HTTP 200, GetCapabilities returns 371 KB)
- Layer A — Zones: `ogdwien:ENERGIERAUMPLANOGD`
- Layer B — Buildings: `ogdwien:GEBAEUDEINFOOGD`
- Snapshot: 2026-05-01

## Game-changer
The buildings layer has a pre-populated `ACD` column. The POC is now **a cross-validation exercise**: spatial join vs. native ACD vs. zone-side GEBID. Disagreement is a finding.

## Next steps
1. [ ] Initial commit + push to `JohnGavin/acd_area_climate_design` (in progress)
2. [ ] File issue for code alignment to real schema (BAUJAHR/BEZ/STRNAML/GESCH_ANZ for buildings; ERPLABEL/FL_ERP/BEZNR/GEBID for zones; drop ERPTYP/ERPRECHTSTAT/HOEHE/ADRESSE assumptions)
3. [ ] Generate default.nix via rix from rix.setup shell; re-apply udunits + shellHook patches
4. [ ] Smoke-test fetch (zones max_features=50, buildings max_features=500)
5. [ ] Update join to include `acd_agreement` factor (compares spatial join, native ACD, zone GEBID)
6. [ ] Render dashboard locally (quarto render vignettes/articles/dashboard.qmd)
7. [ ] Add 7th tab to missing-link page: "ACD agreement" (spatial=native / mismatch / spatial_only / acd_only / neither)
8. [ ] Deploy to GitHub Pages (`docs/` directory pattern from maps template)
9. [ ] Consider Stage 2 storage: copy Parquet to `docs/data/` and flip dashboard to `source = "remote"` for `duckplyr::read_parquet_duckdb()` queries

## Resolved unknowns
- ✅ Real WFS layer names verified
- ✅ Real column names verified (see STUBS.md "Real WFS Schemas")
- ✅ District info: `BEZ` on buildings, `BEZNR` on zones — no separate boundary fetch needed
- ✅ Storage architecture: tier 1 inst/extdata, tier 2 GitHub Pages + duckplyr

## Open unknowns
- Whether all-Vienna fits in single WFS request (may need pagination via `startIndex` + `count`)
- ACD column semantics: is it a binary "yes/no", an ERPLABEL ID, or a free-form classification? Sample fetch will reveal.
- WFS response includes `WEBLINK_VO` (legal document URL) on zones — useful for the dashboard "stories" tab to link directly to the legal text.

## Architecture
- `R/snapshot.R` — constants (now correct: ENERGIERAUMPLANOGD, GEBAEUDEINFOOGD)
- `R/fetch_acd_zones.R`, `R/fetch_buildings.R` — WFS pulls (any_of() column rename guards in place)
- `R/join_buildings_zones.R` — spatial join with diagnostic link_status
- `R/load_data.R` — local/remote dispatcher (duckplyr for remote)
- `R/missing_data_cases.R` — per-case helpers
- `vignettes/articles/dashboard.qmd` — 6-page Quarto, will need 7th tab for ACD agreement
- `inst/extdata/*.parquet` — committed snapshots
- `analysis/rationale/DECISIONS.md` — forking-paths log
- `STUBS.md` — pinned conventions (now reflects real schema)

## Decisions
- 2026-05-01: Pivoted from "build the join" to "validate the pre-linked join" — stronger POC story; documented in CHANGELOG and STUBS.md.

## Tasks to file as GitHub issues after first push
1. Align fetch + join code to real WFS schema (replace assumed column names)
2. Add `acd_agreement` factor to joined schema + new dashboard tab
3. Generate default.nix via rix and apply patches
4. Smoke-fetch + render dashboard
5. Deploy to GitHub Pages with stage-2 remote storage
