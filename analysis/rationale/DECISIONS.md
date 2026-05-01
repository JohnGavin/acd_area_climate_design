# Decision Log

## 2026-05-01: Snapshot pinning by date

**Category:** other (reproducibility)
**Decided:** Pin all data fetches to a single SNAPSHOT_DATE constant in R/snapshot.R.
**Alternatives considered:**
1. Live WFS pulls every render — rejected: not reproducible, breaks if WFS down
2. Date as targets parameter — rejected: overengineered for POC
**Rationale:** Single source of truth. To refresh, bump constant + re-run fetch.
**Decided BEFORE seeing:** any data
**Decided AFTER seeing:** prompt.md description of WFS sources

## 2026-05-01: Centroid-based spatial join (not area-weighted)

**Category:** model (analytical method)
**Decided:** Join buildings to zones via st_within(st_centroid(building), zone)
**Alternatives considered:**
1. st_intersects on full footprint — rejected: ambiguous when straddling
2. Area-weighted overlap — deferred: more correct but slower, beyond POC scope
3. st_covers — rejected: too strict, excludes buildings touching zone edge
**Rationale:** Centroid join is unambiguous (every building gets ≤1 primary zone) and ~10x faster than area-weighted. Straddle cases flagged via separate overlap_fraction column for the diagnostic tabset.
**Decided BEFORE seeing:** any data
**Decided AFTER seeing:** the documented edge cases (straddle, multi-zone)

## 2026-05-01: link_status as diagnostic enum

**Category:** model (output schema)
**Decided:** Add factor column link_status with 6 levels covering every missing-link case.
**Rationale:** Drives the dashboard tabsets directly. Distinguishes "outside any zone" (legitimate) from data errors (invalid_geometry). One column, one source of truth.
**Decided BEFORE seeing:** any data
