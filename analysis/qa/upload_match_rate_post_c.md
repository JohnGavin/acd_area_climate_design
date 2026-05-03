# Post-C match-rate measurement (2026-05-03)

Source: `/Users/johngavin/Downloads/ACD TEST V2.xlsx` (2,039 rows)
Address reference: `/private/tmp/acd_48/docs/data/addresses_2026-05-02.parquet`
REST API: `https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo`
Concurrency: 8 | Max calls: 250 | Timeout: 5s

## Headline

| Approach | Matched | Total | Rate |
|---|---:|---:|---:|
| Baseline (exact only, pre-#37) | 1,661 | 2,039 | 81.5% |
| Post-A+B (#37) | 1,921 | 2,039 | 94.2% |
| **Post-A+B+C (this run)** | **1,976** | **2,039** | **96.9%** |
| Target | ≥ 2,000 | 2,039 | ≥ 98% |

## Fix C REST API results

- Unmatched rows entering Fix C: **118**
- REST API calls made: **118**
- Additional matches via REST: **55** (46.6% of residual)
- No match from REST API: **63**
- API errors: **0**
- Over-budget (skipped): **0**
- Elapsed time for REST calls: **4.0s**

## Sample REST-resolved rows (first 10)

| PLZ | Strasse | HausNr | ACD | Ranking |
|---|---|---|---|---:|
| 1220 |  Brabbeegasse  | 3 | `110543` | 0.0 |
| 1210 |  Arbeiterstrandbadstrasse  |  122C  | `094103` | 9e-08 |
| 1220 |  Brabbeegasse  | 5 | `117639` | 0.0 |
| 1220 |  Brabbeegasse  | 1 | `084328` | 0.0 |
| 1220 |  Brabbeegasse  | 2 | `107413` | 0.0 |
| 1210 |  Bernreiterpl.  | 13 | `247392` | 0.0 |
| 1220 |  Brabbeegasse  | 4 | `084329` | 0.0 |
| 1210 |  Amtsstrasse  |  21-25  | `248486` | 0.0023 |
| 1220 |  Brabbeegasse  | 6 | `084330` | 0.0 |
| 1220 |  Brabbeegasse  | 15 | `084335` | 0.0 |

## Assessment

**Target NOT reached** — match rate 96.9% < 98%. REST API recovered 55 of 118 residual rows.

## Notes

- Fix C tested at concurrency 8, max 250 calls, 5s timeout
  — same parameters as the JS `restFallback()` function in `upload.qmd`.
- Run date: 2026-05-03 20:04 UTC
- See `analysis/qa/upload_match_rate_post_a_b.md` for the A+B baseline.
- CORS behaviour (browser origin vs Python HTTP client) may differ; see
  report section for CORS test result.
