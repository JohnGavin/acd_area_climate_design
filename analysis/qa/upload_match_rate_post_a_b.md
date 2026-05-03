# Post-A+B match-rate measurement (2026-05-01)

Source: `/Users/johngavin/Downloads/ACD TEST V2.xlsx` (2,039 rows)
Address reference: `/private/tmp/acd_37/docs/data/addresses_2026-05-02.parquet` (149,676 unique tuples)
Algorithm: upload.qmd JS logic reproduced in Python (Fix A + Fix B active)

## Headline

| Approach | Matched | Total | Rate |
|---|---:|---:|---:|
| Baseline (exact only, pre-#37) | 1,661 | 2,039 | 81.5% |
| **Post-A+B (this run)** | **1,921** | **2,039** | **94.2%** |
| Target | ≥ 1,897 | 2,039 | ≥ 93% |

## Breakdown by match quality

| match_quality | Count | % of total |
|---|---:|---:|
| `exact` | 1,661 | 81.5% |
| `fuzzy_nearest_house` (Fix A) | 246 | 12.1% |
| `split_both` (Fix B) | 13 | 0.6% |
| `split_partial` (Fix B) | 1 | 0.0% |
| `unmatched` | 118 | 5.8% |

## Assessment

Target REACHED — match rate 94.2% >= 93%.

## Notes

- Fix A (fuzzy nearest house): recovers rows where the exact house number is absent from ADRESSENOGD
  but the street IS present.  Distance capped at 20.
- Fix B (composite split): rows where `Strasse` contains `/` are split into two sub-attempts;
  both, one, or neither side may match.
- Remaining unmatched (118 rows, 5.8%) include: pure Schrebergarten parcel
  addresses, streets genuinely absent from ADRESSENOGD, and empty house numbers.
- Fix C (REST API fallback) and Fix D (multi-unit dedup) tracked as separate issues.
