# Upload page match-rate analysis (2026-05-03)

Source dataset: user's `ACD TEST V2.xlsx`, 2,039 rows (mostly Bezirke 21 Floridsdorf and 22 Donaustadt).
Algorithm under test: `vignettes/articles/upload.qmd` post-#47 (DuckDB-WASM JOIN against `ogdwien:ADRESSENOGD` 291,823-row Parquet, exact match on (PLZ, street_norm, house_norm)).

## Headline

| Approach | Match rate |
|---|---:|
| Old spatial join (pre-#28) | 7.3% (148/2,039) |
| **Current upload page (#28 + #47)** | **81.5% (1,661/2,039)** |
| OGDAddressService REST API (the advice that prompted #28) | ~94.5% (claimed externally; not yet replicated) |

The 81.5% reproduces the baseline I measured before the agent implemented #28; the implementation hit the predicted floor exactly. Improvement vs the old spatial pipeline is ~11×.

The 13-percentage-point gap to the REST API number is closeable in two passes (A+B below) without any external API call.

## The 19% gap (378 unmatched rows)

Failure-mode breakdown:

| Failure category | Count | % of unmatched | % of total file |
|---|---:|---:|---:|
| Street in ADRESSENOGD with same PLZ, but the user's specific HausNr isn't a registered address | **246** | **65%** | 12.1% |
| Street truly not in ADRESSENOGD at all | 131 | 35% | 6.4% |
| ‒ of which composite "X/Y" Schrebergarten address | 52 | 14% | 2.5% |
| ‒ of which has "Parz" in HausNr/Stiege | 72 | 19% | 3.5% |
| Empty HausNr | 8 | 2% | 0.4% |

The 246-row cohort is the dominant problem and is **fuzzy-recoverable**: typically a parcel number, range like "21-25", or a number we don't have in ADRESSENOGD even though the street exists. Returning the nearest existing house number with `match_quality = "fuzzy"` would recover most of these.

The 131 truly-absent rows are mostly Schrebergärten (garden plots): composite addresses like `Achengasse 4/Lavantgasse 1a` with `Parz 38` qualifiers. Composite-street splitting would recover the non-parcel cases (~50 rows). True parcels (~50 rows) genuinely have no ACD because they're not regular buildings — they should remain `unmatched` cleanly.

## The hidden correctness concern: multi-unit dedup ambiguity

ADRESSENOGD has 291,823 rows but only **148,444 unique `(PLZ, street, house)` tuples**. **19,319 of those tuples (13%) have MORE THAN ONE ACD** — multi-unit buildings, staircases, sub-addresses.

The current upload page's lookup table is deduplicated on `(PLZ, street, house)` keeping whichever row sorted first. So when a user looks up "Achengasse 4, 1210" they get **one of the 82 valid ACDs arbitrarily**, possibly not the ACD for their specific unit. This is invisible in the 81.5% match-rate number (no ground truth) but is real and affects ~13% of matched rows.

The fix (Issue D below) is to return ALL valid ACDs for an ambiguous address with `match_quality = "ambiguous_multi"` and let the user disambiguate by Stiege/RH or by selecting a specific row.

## Path to ~94% match rate

Two fixes, both fit the project's static / no-server architecture:

### Fix A — Fuzzy house number (Issue #37 part 1)

When `(PLZ, street_norm)` matches but `house_norm` doesn't, return the address with the **nearest existing house number** on that street. Annotate `match_quality = "fuzzy_nearest_house"` with the numeric distance.

| Aspect | Detail |
|---|---|
| Assumption | Nearest house number on the same street is a reasonable proxy for the user's unfound number |
| Benefit | Recovers ~10 percentage points (≈205 of the 246-row cohort) |
| Cost | Sometimes returns a neighbour's ACD, not the user's. Distance score lets the user filter. |
| Works on | "Achengasse 21" missing → nearest "Achengasse 19" or "23" found |
| Doesn't work on | Brand-new buildings, parcels-as-house-numbers ("Parz 38") |

### Fix B — Composite-street splitter (Issue #37 part 2)

Strings like `Achengasse 4/Lavantgasse 1a` contain TWO addresses. Split on `/` and try each side independently. Return BOTH ACDs (`acd_a`, `acd_b`) with `match_quality = "split_both"`, or one with `match_quality = "split_partial"` if only one side matches.

| Aspect | Detail |
|---|---|
| Assumption | Composite addresses identify corner parcels at the intersection of two streets; both addresses are valid for the same physical building |
| Benefit | Recovers ~3 percentage points (50 of the 131 truly-absent rows) |
| Cost | Returning two ACDs requires UI handling for the ambiguity |
| Works on | "Achengasse 4/Lavantgasse 1a" → `acd_a = 070238` (Achengasse 4), `acd_b = ...` (Lavantgasse 1a) |
| Doesn't work on | Pure Schrebergarten parcels with no street component |

### Fix C — REST API fallback (Issue TBD)

For rows still unmatched after A+B, optionally call the city's [`OGDAddressService.svc/GetAddressInfo`](https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo) per row with rate-limit budget (concurrency cap 8, max ~250 calls). The REST API does its own fuzzy matching and returns the canonical ACD.

| Aspect | Detail |
|---|---|
| Assumption | The REST API is more permissive than our static Parquet for Schrebergärten and edge-case spellings |
| Benefit | ~1-2 additional percentage points + canonicalises multi-unit ambiguity for those rows |
| Cost | Network calls (each ~200 ms), not offline-capable, may drift if the city changes the API |
| Works on | Schrebergarten parcels that the API resolves to a base address |
| Doesn't work on | Truly nonexistent addresses |

### Fix D — Multi-unit dedup fix (Issue TBD)

Replace `drop_duplicates(keep="first")` with `GROUP BY` + `array_agg(acd)` so a matched row returns ALL ACDs for an ambiguous address. UI shows the count and lets the user accept all or pick.

| Aspect | Detail |
|---|---|
| Assumption | The user knows their own building's unit / Stiege; we shouldn't pick for them |
| Benefit | Eliminates a hidden correctness bug affecting ~13% of matched rows |
| Cost | Requires UI work to render multi-ACD cells |
| Works on | "Achengasse 4" with 82 ACDs → returns all 82 |
| Doesn't work on | (no failure mode — strict improvement) |

## Lessons learnt

### Self-consistency tests must respect duplication

My first attempt at a 10k self-consistency test sampled rows from ADRESSENOGD itself and asked "did the dedup return the row I sampled?" The result (99.7% matched, 56.5% correct) was a test artifact, not a real bug — I had guaranteed failure on the 13% of multi-unit tuples by sampling random rows from groups while the dedup kept only one. **A correct self-consistency test samples one row PER unique key and accepts any of the valid ACDs as correct.**

### "Match rate" alone hides the multi-unit problem

The 81.5% headline number says how many rows got SOME ACD back. It does not say whether the ACD returned is the right one for the user's unit. With 13% of tuples being multi-ACD, up to 13% of the matched rows could be subtly wrong. This is an honest caveat the methodology should disclose.

### The REST API claim of 94.5% may include silent multi-unit picks too

The REST API returns one ACD per query. Its 94.5% match rate doesn't say which of multiple valid ACDs it returns for a multi-unit building either. Comparing our match rate to the REST API's number assumes both are picking the same canonicalisation — they might not be. **Direct comparison should ground-truth at least 100 multi-unit cases by hand to see whose pick aligns with the user's intent.**

### A working algorithm hits the predicted floor exactly

I forecast 81.5% before the agent built #28. The agent shipped 81.5%. The "disappointment" was vs an aspirational 94.5% (REST API), not vs the floor. Lesson: communicate **two numbers** when forecasting algorithm performance — the floor (what we know works on this static-deploy architecture) and the ceiling (what the external comparison reaches with extra capabilities). Don't let the ceiling become the implicit target without flagging the gap.

### Validator coverage is structural, not functional

`acd::validate_deploy()` confirms the upload page renders without errors and the assets resolve. It says nothing about whether the algorithm gives correct ACDs. **Functional validation needs a separate test harness (#46) that asserts per-row gold-standard ACDs against a curated test corpus.**

## Files

- This analysis: `analysis/qa/upload_match_rate_analysis.md`
- Source measurement scripts: ad-hoc Python in 2026-05-03 session — not committed; rerun-ready by querying the user's xlsx + the ADRESSENOGD Parquet
- Related issues: #37 (fuzzy + composite — A+B), TBD (REST fallback — C), TBD (multi-unit dedup — D), #46 (graded test corpus, separate)
