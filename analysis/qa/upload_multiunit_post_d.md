# Post-D multi-unit diagnostic (2026-05-03)

Source: `/private/tmp/acd_49/inst/extdata/addresses_2026-05-02.parquet`

## ADRESSENOGD multi-unit summary

| Metric | Value |
|---|---:|
| Total rows in ADRESSENOGD | 291,823 |
| Unique `(PLZ, street, house)` tuples | 148,444 |
| Tuples with `acd_count > 1` (multi-unit) | 19,319 |
| Fraction of tuples that are multi-unit | 13.0% |

## Headline example: Achengasse 4, 1210

PLZ `1210`, street `achengasse`, house `4` → **82 ACDs**.

```
070237,070238,070240,070241,119505,120717,136469,136470,136471,136473,136476,145035,145063,145077,145082,145118,145124,145260,145269,145272,145276,145288,145306,145310,145318,145324,145337,145343,1453
```

## Top-5 most ambiguous addresses in ADRESSENOGD

| PLZ | Street | House | acd_count | First few ACDs |
|---|---|---|---:|---|
| 1100 | holzknechtstraße | 64 | 713 | `018912,018913,018914,105039,105040,108199,109805,112164,1181…` |
| 1100 | laaer-berg-straße | 226 | 568 | `018912,018913,018914,105039,105040,108199,112164,118120,1191…` |
| 1100 | alaudagasse | 40 | 536 | `018912,018913,018914,105040,108199,112164,118120,122869,1287…` |
| 1100 | benischkegasse | 2 | 484 | `018912,018913,018914,105040,108199,109805,112164,118120,1228…` |
| 1100 | braheplatz | 12 | 424 | `112568,118294,127392,127663,135488,140607,140626,140630,1406…` |

## Per-row match analysis (user test file: 2,039 rows)

| Metric | Value |
|---|---:|
| Total matched rows (Fix A+B) | 1,921 |
| Rows flagged `ambiguous_multi` | 472 |
| Fraction of matched rows that are ambiguous | 24.6% |

### Ambiguous rows in the test file (first 5)

| Input row | PLZ | Street | House | acd_count | ACDs (truncated) |
|---:|---|---|---|---:|---|
| 1 | 1210 | Achengasse | 3 | 3 | `070268,211792,216893` |
| 2 | 1210 | Achengasse | 4 | 82 | `070237,070238,070240,070241,119505,120717,136469,136470,136471,136473,136476,145…` |
| 87 | 1220 | Am Freihof | 21 | 3 | `092522,241338,241339` |
| 132 | 1220 | Am langen Felde | 6 | 2 | `112261,243211` |
| 134 | 1220 | Am langen Felde | 12 | 2 | `241812,241813` |

## Assessment

Fix D replaces the silent arbitrary-ACD dedup with `GROUP BY + ARRAY_AGG`.
The match rate is unchanged because all previously-matched rows are still
matched — only the `match_quality` label changes for the ambiguous cohort.

- **19,319 unique address tuples (13.0%)** in ADRESSENOGD
  have more than one valid ACD.  Previously these returned an arbitrary ACD;
  now they return `acd_count` + `acd_codes` with `match_quality = ambiguous_multi`.
- **472 of 1,921 matched rows** in the
  test file (24.6%) are now flagged `ambiguous_multi`.

Run date: 2026-05-03 20:17
