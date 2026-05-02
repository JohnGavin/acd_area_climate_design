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

## 2026-05-01: Stage 2 — Use OSM as independent coverage baseline

**Category:** other (data source selection)
**Decided:** Query OpenStreetMap via Overpass API (osmdata R package + httr2 fallback) to
count Vienna buildings independently of OGD, then compare to GEBAEUDEINFOOGD totals.
**Alternatives considered:**
1. BEV/GWR (Austrian building register) — deferred per Stage 0 recommendation; requires
   data agreement, not freely queryable.
2. GEBAEUDETYPOGD (438k features) — rejected for this analysis; lacks rich attributes
   (EY, HJ, GF) needed for energy-zone linkage. Using it as a cross-check would only
   answer "how many types" not "how many buildings with attributes".
3. Vienna Stadtplan WMS — rejected; raster service, not suitable for counting features.
4. Scraping MA37/MA41 permit database — rejected; no public API, legal uncertainty.
**Rationale:** OSM is free, no authentication, global coverage, and independently
community-maintained. `osmdata` provides a clean R interface. City-wide count (307,715)
answers issue #14 definitively without requiring data agreements.
**Decided BEFORE seeing:** OSM totals
**Decided AFTER seeing:** Stage 0 finding that OGD data is a curated subset

## 2026-05-01: Stage 2 — Bbox-based per-district Overpass count (not polygon clip)

**Category:** model (analytical method)
**Decided:** Use per-district bounding-box Overpass queries for district-level breakdown,
not full geometry pull + polygon clip.
**Alternatives considered:**
1. Full geometry pull (osmdata_sf) + st_intersects polygon clip — attempted but Overpass
   rate-limited on second attempt; first run took 302s for 307k features. Risk of hitting
   daily quotas. Also requires >1GB RAM for sf operations on 307k polygons.
2. Overpass area-based queries (administrative boundary lookup) — tried; OSM area names
   for Vienna districts are inconsistent across the dataset, making string matching
   unreliable.
3. Four-quadrant bbox split + union — would avoid rate limiting but adds complexity.
**Rationale:** Bbox queries are lightweight (count-only, no geometry returned), complete
in <90s per district, and don't risk rate-limiting. The bbox-vs-polygon difference biases
outer-district counts upward; this limitation is documented in the report and is
acceptable for the purpose of confirming the hypothesis (undercount), not precise
measurement.
**Decided BEFORE seeing:** per-district results
**Decided AFTER seeing:** Overpass rate-limit failure on second full-geometry pull
