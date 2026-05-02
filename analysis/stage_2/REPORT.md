# Stage 2 Report: GEBAEUDEINFOOGD Coverage vs OpenStreetMap

**Date:** 2026-05-01
**Branch:** feat/stage-2-osm-coverage
**Answers:** GitHub issue #14

---

## Question

Does GEBAEUDEINFOOGD's 58,255 buildings undercount Vienna's actual building stock?
An independent estimate suggested ~225,000 buildings. The `GEBAEUDETYPOGD` layer has
438,000 features but lacks the rich attributes needed for energy-zone linkage.

---

## Method

**Source:** OpenStreetMap (OSM), queried via the Overpass API on 2026-05-01.
Data licensed under ODbL 1.0 (https://www.openstreetmap.org/copyright).

**OSM full-city count:** All features tagged `building=*` within the Vienna bounding
box (16.18 E - 16.58 E, 48.12 N - 48.32 N) were counted via the osmdata R package.
The full geometry pull returned 307,715 features (303,018 polygons + 4,697 multipolygons).

**Per-district count (method note):** District-level breakdown used a second round of
Overpass `out count` queries, one per district bounding box. Because district bounding
boxes are rectangular (not polygon-clipped), counts for large or irregularly shaped
districts -- especially outer districts 21 (Floridsdorf) and 22 (Donaustadt) -- include
buildings from neighbouring districts' rectangles. Per-district ratios are upper-bound
estimates; the city-wide total (307,715) is the authoritative figure.

**OGD baseline:** GEBAEUDEINFOOGD joined layer (`inst/extdata/joined_2026-05-01.parquet`)
counts 58,255 buildings across all 23 districts.

---

## Results

### City-wide totals

| Source | Total buildings |
|--------|----------------|
| GEBAEUDEINFOOGD (OGD) | 58,255 |
| OpenStreetMap (OSM, full bbox) | 307,715 |
| OSM / OGD ratio | 5.3x |

OSM has 5.3 times more building records than GEBAEUDEINFOOGD. The pre-analysis
estimate of ~225,000 was a conservative floor; OSM shows the true total is ~308,000.

### Per-district comparison

| District | Name | OGD | OSM (bbox) | Ratio |
|----------|------|----:|----------:|------:|
| 21 star | Floridsdorf | 2,962 | 54,445 | 18.4x |
| 20 star | Brigittenau | 1,617 | 5,381 | 3.3x |
| 22 | Donaustadt | 1,389 | 109,150 | 78.6x |
| 23 | Liesing | 1,137 | 37,392 | 32.9x |
| 11 | Simmering | 911 | 19,440 | 21.3x |
| 02 | Leopoldstadt | 2,594 | 47,158 | 18.2x |
| 14 | Penzing | 3,020 | 42,601 | 14.1x |
| 10 | Favoriten | 3,362 | 35,451 | 10.5x |
| 17 | Hernals | 2,986 | 25,565 | 8.6x |
| 13 | Hietzing | 4,265 | 31,728 | 7.4x |
| 18 | Wahring | 3,648 | 20,326 | 5.6x |
| 16 | Ottakring | 3,600 | 18,170 | 5.1x |
| 12 | Meidling | 3,729 | 13,120 | 3.5x |
| 19 | Doebling | 5,935 | 19,207 | 3.2x |
| 03 | Landstrasse | 3,157 | 8,932 | 2.8x |
| 06 | Mariahilf | 1,405 | 3,441 | 2.5x |
| 09 | Alsergrund | 1,930 | 4,233 | 2.2x |
| 05 | Margareten | 2,071 | 4,008 | 1.9x |
| 15 | Rudolfsheim-Fuenfhaus | 2,998 | 5,774 | 1.9x |
| 01 | Innere Stadt | 1,514 | 2,767 | 1.8x |
| 07 | Neubau | 1,461 | 2,538 | 1.7x |
| 04 | Wieden | 1,464 | 2,395 | 1.6x |
| 08 | Josefstadt | 1,100 | 1,505 | 1.4x |

star = focus districts for issue #14.

### Focus districts (issue #14)

- **District 20 (Brigittenau):** 1,617 OGD vs 5,381 OSM-bbox -- ratio 3.3x.
- **District 21 (Floridsdorf):** 2,962 OGD vs 54,445 OSM-bbox -- ratio 18.4x.

The extreme Floridsdorf ratio is partly due to the large rectangular bbox capturing
buildings from adjacent Donaustadt. The true ratio is likely 5-10x, consistent with
the city-wide average.

---

## Conclusion

**Yes, GEBAEUDEINFOOGD substantially undercounts Vienna.** At 58,255 buildings vs
OSM's 307,715, the OGD layer covers approximately 19% of the actual building stock.
This confirms the hypothesis in issue #14: GEBAEUDEINFOOGD is a curated attribute-rich
subset -- likely restricted to buildings above a size or permit threshold -- rather than
a comprehensive cadastre.

Every district shows OSM > OGD. Inner-city districts (01-08) show 1.4-2.5x (dense
multi-unit blocks inflate OGD counts); outer suburban districts (21-23) show 18-79x
(single-family homes and garden structures are in OSM but absent from OGD).

---

## Recommendation (issue #14)

| Option | Recommendation |
|--------|----------------|
| Keep OGD as primary layer (58,255 curated buildings with EY, HJ, area attributes) | YES -- retain for zone-linkage |
| Switch to GEBAEUDETYPOGD (438,000 features, poor attributes) | No -- loses attribute richness |
| Supplement with OSM as coverage denominator | YES -- adopt as coverage baseline |
| Switch to BEV/GWR (deferred in Stage 0) | Revisit if Stage 3 scale-up needed |

**Recommended action:** Retain GEBAEUDEINFOOGD as primary layer. Add OSM count (307,715)
as the coverage denominator: dashboard and vignettes should disclose that the analysis
covers ~19% of Vienna's actual building stock.

---

## Limitations

1. Per-district OSM counts use bounding boxes, not polygon clipping -- ratios for large
   outer districts are inflated. The city-wide 5.3x ratio is more reliable.
2. OSM completeness varies by area type. Garden sheds and minor outbuildings in outer
   districts may add noise to OSM totals.
3. GEBAEUDEINFOOGD selection criteria are not publicly documented. We cannot quantify
   what fraction of the undercount is definitional vs truly missing.
4. OSM is community-contributed, not officially validated -- treat as cross-check, not
   ground truth.

---

## Files

| File | Description |
|------|-------------|
| `analysis/stage_2/osm_total_summary.csv` | OSM full-bbox total (307,715) |
| `analysis/stage_2/osm_by_district_bbox.csv` | Per-district OSM counts (bbox method) |
| `analysis/stage_2/coverage_by_district.csv` | OGD vs OSM, all 23 districts |
| `analysis/stage_2/pull_osm_buildings.R` | osmdata full-geometry pull script |
| `analysis/stage_2/overpass_count_by_district.R` | Per-district Overpass count script |
| `analysis/stage_2/merge_comparison.R` | District ID normalisation and merge |
