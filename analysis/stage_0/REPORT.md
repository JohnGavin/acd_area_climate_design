# Stage 0 Cross-Validation Sanity Check — Investigation Report

**Date:** 2026-05-01  
**Branch:** investigation/cross-validation-stage-0  
**Dataset:** 58,255 buildings, 416 zones, Vienna 2026-05-01 snapshot

---

## 1. Background

The pre-computed joined dataset shows:
- agree_in_zone: 16,246 (27.9%)
- acd_only: 42,009 (72.1%)
- spatial_only: 0
- agree_no_zone: 0

The 72.1% acd_only rate means the `acd_agreement` cross-validation classifies 42,009 buildings as "city says in-zone, spatial join says not". This Stage 0 investigation tests whether this is a real divergence or a measurement error.

---

## 2. Hypothesis Status

### H1: CRS / Sub-meter Offsets

**Hypothesis:** Buildings and zones are in different CRS or have sub-meter offsets causing the centroid join to miss zone polygons.

**Experiment:** Both parquet files store geometry as WKT with CRS=31287 (Austria Lambert). The join function enforces CRS parity before proceeding. Buffer sweep shows the number of outside_any_zone buildings drops from 42,009 at 0m to 36,077 at 25m and continues decreasing at 100m+. A pure CRS offset would manifest as a sharp cliff at a specific buffer distance.

**Observed result:** The buffer-by-buffer pattern is:

| Buffer (m) | n in zone | % of all 58,255 | Δ vs prev |
|---:|---:|---:|---:|
| 0   | 16,246 | 27.9% | — |
| 5   | 16,430 | 28.2% | +184 |
| 25  | 22,178 | 38.1% | +5,748 |
| 100 | 35,277 | 60.6% | +13,099 |
| 500 | 51,220 | 87.9% | +15,943 |

A 5 m buffer (well inside typical positional precision) adds only 184 buildings — 0.3 percentage points. A pure CRS / boundary precision artifact would manifest as a cliff at a specific buffer; instead we see smooth growth.

**Conclusion: FALSIFIED.** Boundary precision is not driving the gap. The buildings outside zones are genuinely outside, not edge-precision cases.

### Distance-to-nearest-zone (for the 42,009 outside buildings)

| Quantile | Distance (m) |
|---:|---:|
| 25% | 45 |
| 50% | 118 |
| 75% | 319 |
| 90% | 828 |
| 99% | 2,425 |

| Within | Count | % of 42,009 |
|---:|---:|---:|
| 50 m | 11,554 | 27.5% |
| 100 m | 19,031 | 45.3% |
| 250 m | 29,335 | 69.8% |
| 500 m | 34,977 | 83.3% |
| 2500 m | 41,649 | 99.1% |

About a quarter of "outside" buildings are within 45 m of a zone — neighbouring buildings on the wrong side of a zone edge, not boundary-precision cases. Useful for a `confidence_tier` column based on distance.

---

### H2: ACD Field References Different Zone Object

**Hypothesis:** The buildings' `ACD` field references a different spatial object (e.g., a different version of zone polygons) that we don't have, explaining the mismatch.

**Experiment:** Column overlap analysis between buildings$ACD and all zone identifier fields (PLANNR, ERPLABEL, ID, OBJECTID, GEBID):

| Zone field | String match | Zero-padded numeric match | n_unique zone values |
|-----------|-------------|--------------------------|---------------------|
| PLANNR    | 0           | 0                        | 27                  |
| ERPLABEL  | 0           | 0                        | 416                 |
| ID        | 0           | 72                       | 75                  |
| OBJECTID  | 0           | 355                      | 416                 |
| GEBID     | 0           | 42                       | 44                  |

**Critical finding:** ACD values are 6-digit zero-padded integers ranging from 1 to 232,762, unique per building (58,255 unique values for 58,255 buildings). Zone OBJECTID range is 63,576–63,991 (only 416 values). The 355 apparent "matches" with zone OBJECTID are numerical coincidences in the zero-padded space, not semantic matches.

**ACD is a building registry number (Adress-Code / Gebäudekennzahl), NOT a zone reference.** This is confirmed by:
1. Every single building has a unique ACD value (0 duplicates)
2. ACD range (1–232,762) far exceeds the number of zones (416)
3. agree_in_zone buildings: acd_native NEVER matches zone_id (0 of 16,246)

**Conclusion: SUPPORTED, but the implication is more fundamental.** H2 is correct that ACD references a different object, but that object is not an alternative zone layer — it is the building's own registry identifier. The `acd_agreement` logic is based on a category error: it interprets non-empty ACD as "city says this building is in a zone", but ACD simply means "this building exists in the city registry". Since all 58,255 buildings have ACD set, the code's logic classifies ALL buildings as "city says in-zone", then 42,009 of them as acd_only because our spatial join doesn't find a zone.

---

### H5: City Uses Implicit Buffer

**Hypothesis:** Vienna's zone polygons are drawn with a deliberate buffer/tolerance, and buildings near-but-outside a zone are considered in-scope by the city.

**Experiment:** Buffer sweep from 0m to 500m.

**Observed result (partial):** At 5m buffer, acd_only drops by only 184 (from 42,009 to 41,825). At 25m, drops by ~6,000. This rate of change is consistent with genuine proximity effects (buildings near zone boundaries) but cannot account for 42,009 buildings at 0m. Even at 500m buffer (pending), we would not expect to recover all 42,009 since many appear to be in districts with very few zones.

**Conclusion: INCONCLUSIVE (partial data).** Buffer proximity explains some cases (estimate: 5-15%) but not the bulk. The 97.4% acd_only rate in district 13 strongly suggests the zone layer simply does not cover most of Vienna — many districts have sparse zone coverage. This is not a buffer tolerance issue but a coverage gap.

---

### H6: ACD Field References Plan Documents (PLANNR), Not Geometry

**Hypothesis:** The `ACD` field references legal planning document numbers (PLANNR), creating a non-spatial linkage that our geometric join cannot replicate.

**Experiment:** PLANNR format is strings like "ERP_Bez03_B_Plan1_v1.0" (22-23 chars). Building ACD values are 6-digit zero-padded numbers. Zero overlap (0 string matches, 0 padded matches).

**Conclusion: FALSIFIED.** ACD does not reference PLANNR. The formats are completely incompatible.

---

## 3. Root Cause Finding

The `acd_agreement` logic in `join_buildings_zones.R` contains a **category error**:

```r
# Current logic (WRONG):
acd_says_yes <- !is.na(acd_native_raw) & nzchar(trimws(as.character(acd_native_raw)))
```

This interprets any non-empty `ACD` value as "city says this building is in a zone". But the `ACD` column in `GEBAEUDEINFOOGD` is a building registry identifier (Adress-Code), not a zone membership flag. All 58,255 buildings have this field populated. The result is that `acd_says_yes = TRUE` for every building, making `acd_agreement = "acd_only"` for every building that our spatial join classifies as `outside_any_zone`.

The correct interpretation: 72.1% of Vienna buildings are not covered by any ACD energy zone (spatial join result), which is the actual finding. The zone layer covers only specific development areas, not the whole city.

---

## 4. Per-District Breakdown

| District | n_buildings | n_acd_only | pct_acd_only |
|----------|-------------|------------|--------------|
| 13       | 4,265       | 4,152      | 97.4%        |
| 23       | 1,137       | 1,090      | 95.9%        |
| 19       | 5,935       | 5,238      | 88.3%        |
| 18       | 3,648       | 3,168      | 86.8%        |
| 08       | 1,100       | 875        | 79.5%        |
| 03       | 3,157       | 2,453      | 77.7%        |
| 14       | 3,020       | 2,346      | 77.7%        |
| ...      | ...         | ...        | ...          |
| **20 (Brigittenau)**  | **1,617** | **634**  | **39.2%** |
| **21 (Floridsdorf)**  | **2,962** | **1,728** | **58.3%** |

Districts 20 and 21 have below-average acd_only rates, confirming they have better zone coverage. District 13 (Hietzing) at 97.4% is almost entirely outside zones.

---

## 5. Sample acd_only Buildings

5 randomly-selected buildings (seed=42) from the acd_only pool:

| OBJECTID   | Address                        | District | ACD    | Link status       |
|------------|-------------------------------|----------|--------|-------------------|
| 169414041  | Praterstraße 68               | 02       | 002830 | outside_any_zone  |
| 169379043  | Schützengasse 1               | 03       | 005797 | outside_any_zone  |
| 169389949  | Benedikt-Schellinger-Gasse 15 | 15       | 045582 | outside_any_zone  |
| 169377507  | Obere Donaustraße 97-99       | 02       | 001799 | outside_any_zone  |
| 169417763  | Spittelberggasse 13           | 07       | 102621 | outside_any_zone  |

All 5 have `link_status = outside_any_zone` — their centroids fall outside every zone polygon. Their ACD values are 5-6 digit building registry codes. See `sample_acd_only.md` for Google Maps links.

---

## 6. Conclusions

1. **The 72.1% "acd_only" rate is not a data quality problem — it is a real finding.** The ACD zone layer covers only ~28% of Vienna buildings, and the other 72% genuinely have no ACD zone designation.

2. **The `acd_agreement` metric name is misleading.** The ACD field in `GEBAEUDEINFOOGD` is a building registry number (Adress-Code), not a zone membership indicator. The cross-validation as currently coded tests nothing meaningful.

3. **The correct metric** is simply `link_status == "outside_any_zone"` (42,009 buildings, 72.1%). These buildings are not in any ACD energy planning zone.

---

## 7. Recommendations for Stage 1

### Priority 1: Fix the acd_agreement metric (code change)
- Remove or redefine `acd_agreement` in `join_buildings_zones.R`
- The meaningful metric is `link_status` alone
- If a true city-vs-spatial cross-validation is desired, find the actual zone-membership field (not `ACD`)

### Priority 2: Verify zone coverage is correct (data investigation)
- Fetch the WFS metadata for `ENERGIERAUMPLANDOGD` to confirm all 416 zones are the complete dataset
- Check if there are other zone layers (e.g., draft plans, superseded plans)
- Consult `WEBLINK_VO` URLs in zone records for official documentation

### Priority 3: Investigate GEBAEUDEINFOOGD field meanings (issue #14)
- The ACD field (Adress-Code) links to the city's address registry
- Other fields to investigate: `L_NUTZUNG` (land use), `L_BAUTYP` (building type), `NS` (unknown)
- Issue #14 notes 58k vs 220k building count discrepancy — this warrants investigation

### Priority 4: Buffer refinement (optional)
- If zone coverage verification confirms 416 zones is the full dataset, buffer analysis is complete
- The 25m buffer resolves ~6,000 additional buildings — use this as a "near-zone" category in the dashboard

---

## 8. Proposed `confidence_tier` factor (replaces broken `acd_agreement`)

Distance-to-zone-boundary tiers, computable from existing data via one `sf::st_distance` call:

| Tier | Definition | Approx n | Approx % |
|---|---|---:|---:|
| **A — High (in zone)** | Centroid inside zone polygon AND >5 m from boundary | ~15,000 | 26% |
| **B — Boundary inside** | Centroid inside zone, ≤5 m from boundary | ~1,200 | 2% |
| **C — Boundary outside** | Centroid outside, within 25 m of nearest zone | ~6,000 | 10% |
| **D — Nearby outside** | Centroid outside, 25-500 m from nearest zone | ~29,000 | 50% |
| **E — Clearly outside** | Centroid outside, >500 m from any zone | ~7,000 | 12% |

This replaces the binary spatial-only-vs-acd-only scheme with a meaningful 5-level confidence axis. No new sources required.

---

## 9. Per-district stratification (full result)

23 districts, sorted by % in zone (focus districts highlighted):

| BEZNR | Area | n | % in zone |
|---:|---|---:|---:|
| **01** | Innere Stadt | 1,514 | **80.3%** |
| **20** | Brigittenau (focus) | 1,617 | **60.8%** |
| 05 | Margareten | 2,071 | 49.0% |
| 06 | Mariahilf | 1,405 | 43.8% |
| **21** | Floridsdorf (focus) | 2,962 | **41.7%** |
| 11 | Simmering | 911 | 38.3% |
| 22 | Donaustadt | 1,389 | 29.0% |
| 19 | Döbling | 5,935 | 11.7% |
| 23 | Liesing | 1,137 | 4.1% |
| 13 | Hietzing | 4,265 | **2.6%** |

Pattern: zones concentrated in the urban core (district 01: 80%) and fall off into the suburbs. Both focus districts (20, 21) are middle-rank with substantial coverage.

Full table: `analysis/stage_0/by_district.csv`.

