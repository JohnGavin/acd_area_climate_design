#!/usr/bin/env python3
"""
Post-D multi-unit diagnostic for upload.qmd Fix D (array_agg dedup correctness).

Mirrors the DuckDB-WASM GROUP BY logic in Python to report:
  - How many unique (PLZ, street, house) tuples have acd_count > 1
  - How many of the matched rows in the test file are flagged ambiguous_multi
  - A concrete example showing N > 1 ACDs

Inputs:
  - /Users/johngavin/Downloads/ACD TEST V2.xlsx  (user's 2,039-row test file)
  - /private/tmp/acd_49/inst/extdata/addresses_2026-05-02.parquet  (ADRESSENOGD)

Output:
  - analysis/qa/upload_multiunit_post_d.md  (markdown report)
"""

import re
import sys
import pandas as pd
import pyarrow.parquet as pq
from pathlib import Path
from datetime import datetime

# ── Paths ─────────────────────────────────────────────────────────────────
XLSX_PATH    = "/Users/johngavin/Downloads/ACD TEST V2.xlsx"
PARQUET_PATH = "/private/tmp/acd_49/inst/extdata/addresses_2026-05-02.parquet"
OUT_MD       = Path(__file__).parent / "upload_multiunit_post_d.md"
FUZZY_MAX_DIST = 20

# ── Helpers ────────────────────────────────────────────────────────────────
def detect_col(cols, keys):
    for c in cols:
        if re.sub(r'[^a-z]', '', c.lower()) in keys:
            return c
    return cols[0]


def extract_trailing_number(s):
    m = re.search(r'(\d+\w*)$', s.strip())
    return m.group(1) if m else None


def split_composite(row, plz_col, street_col, house_col):
    plz    = str(row[plz_col]).strip()
    street = str(row[street_col]).strip()
    house  = str(row[house_col]).strip()
    if "/" in street:
        parts = [p.strip() for p in street.split("/") if p.strip()]
        out = []
        for i, part in enumerate(parts):
            trailing   = extract_trailing_number(part)
            street_only = re.sub(r'\s*\d+\w*$', '', part).strip()
            out.append({
                "PLZ":             plz,
                "street_norm":     street_only.lower(),
                "house_norm":      (trailing or house).lower(),
                "composite_index": i,
                "composite_total": len(parts),
            })
        return out
    else:
        return [{
            "PLZ":             plz,
            "street_norm":     street.lower(),
            "house_norm":      house.lower(),
            "composite_index": 0,
            "composite_total": 1,
        }]


def leading_int(s):
    m = re.match(r'^(\d+)', str(s))
    return int(m.group(1)) if m else None


# ── Load ADRESSENOGD ──────────────────────────────────────────────────────
print("Loading ADRESSENOGD Parquet...", file=sys.stderr)
addr_raw = pq.read_table(PARQUET_PATH).to_pandas()
addr_raw["street_norm"] = addr_raw["NAME_STR"].str.lower().str.strip()
addr_raw["house_norm"]  = addr_raw["NAME_ONR"].str.lower().str.strip()
addr_raw["plz_norm"]    = addr_raw["PLZ"].astype(str)

n_raw = len(addr_raw)

# Fix D: GROUP BY equivalent — aggregate all ACDs per (plz_norm, street_norm, house_norm)
addr_grouped = (
    addr_raw
    .groupby(["plz_norm", "street_norm", "house_norm"], sort=False)
    .agg(
        acd_list  = ("ACD",           lambda x: sorted(x.tolist())),
        acd_count = ("ACD",           "count"),
        lon       = ("lon",           "first"),
        lat       = ("lat",           "first"),
    )
    .reset_index()
)
addr_grouped["ACD"]      = addr_grouped["acd_list"].apply(lambda x: x[0])  # first (sorted)
addr_grouped["acd_codes"] = addr_grouped["acd_list"].apply(lambda x: ",".join(x))

n_unique_tuples = len(addr_grouped)
n_multi_tuples  = (addr_grouped["acd_count"] > 1).sum()
pct_multi       = 100 * n_multi_tuples / n_unique_tuples

print(f"ADRESSENOGD: {n_raw:,} rows → {n_unique_tuples:,} unique tuples", file=sys.stderr)
print(f"Multi-unit tuples (acd_count > 1): {n_multi_tuples:,} ({pct_multi:.1f}%)", file=sys.stderr)

# Find the Achengasse 4 example
achen = addr_grouped[
    (addr_grouped["street_norm"] == "achengasse") &
    (addr_grouped["house_norm"] == "4")
]
achen_example = None
if not achen.empty:
    row = achen.iloc[0]
    achen_example = {
        "PLZ":       row["plz_norm"],
        "street":    row["street_norm"],
        "house":     row["house_norm"],
        "acd_count": row["acd_count"],
        "acd_codes": row["acd_codes"],
    }
    print(f"Achengasse 4: {achen_example['acd_count']} ACDs", file=sys.stderr)

# Build lookup index for matching
addr_idx = addr_grouped.set_index(["plz_norm", "street_norm", "house_norm"])

# Also build numeric index for fuzzy
addr_numeric = addr_raw.copy()
addr_numeric["house_int"] = (
    addr_numeric["house_norm"].str.extract(r'^(\d+)').astype(float)
)
addr_numeric = addr_numeric.dropna(subset=["house_int"])
addr_by_street = addr_numeric.groupby(["plz_norm", "street_norm"])

# ── Load user file ────────────────────────────────────────────────────────
print("Loading user xlsx...", file=sys.stderr)
try:
    user_raw = pd.read_excel(XLSX_PATH, dtype=str).fillna("")
    cols       = list(user_raw.columns)
    plz_col    = detect_col(cols, ["plz", "postcode", "zip", "postleitzahl"])
    street_col = detect_col(cols, ["strasse", "street", "strase", "str",
                                   "streetname", "strassename", "name"])
    house_col  = detect_col(cols, ["hausnr", "hnr", "hausnummer", "nr",
                                   "housenumber", "number"])
    print(f"User: {len(user_raw):,} rows | PLZ={plz_col!r} "
          f"Street={street_col!r} House={house_col!r}", file=sys.stderr)
    has_user_file = True
except FileNotFoundError:
    print(f"User file not found at {XLSX_PATH} — skipping per-row analysis",
          file=sys.stderr)
    has_user_file = False

# ── Run Fix A + B passes and detect ambiguous_multi rows ─────────────────
n_ambiguous_matched = 0
n_total_matched     = 0
ambiguous_examples  = []

if has_user_file:
    n_total = len(user_raw)

    def match_row(row):
        """Returns dict with ACD, acd_count, acd_codes, match_quality."""
        street_val = str(row[street_col]).strip()

        # Fix B: composite
        if "/" in street_val:
            parts = split_composite(row, plz_col, street_col, house_col)
            matched_parts = []
            for p in parts:
                key = (p["PLZ"], p["street_norm"], p["house_norm"])
                if key in addr_idx.index:
                    matched_parts.append(addr_idx.loc[key])
            if matched_parts:
                best = matched_parts[0]
                mq = "split_both" if len(matched_parts) == len(parts) else "split_partial"
                return {
                    "ACD":         best["ACD"],
                    "acd_count":   int(best["acd_count"]),
                    "acd_codes":   best["acd_codes"],
                    "match_quality": mq,
                }
            # fall through to exact/fuzzy with original street

        plz_n    = str(row[plz_col]).strip()
        street_n = str(row[street_col]).strip().lower()
        house_n  = str(row[house_col]).strip().lower()
        key = (plz_n, street_n, house_n)

        # Exact
        if key in addr_idx.index:
            r = addr_idx.loc[key]
            cnt = int(r["acd_count"])
            mq  = "ambiguous_multi" if cnt > 1 else "exact"
            return {
                "ACD":         r["ACD"],
                "acd_count":   cnt,
                "acd_codes":   r["acd_codes"],
                "match_quality": mq,
            }

        # Fuzzy (Fix A)
        hi = leading_int(house_n)
        if hi is not None:
            street_key = (plz_n, street_n)
            if street_key in addr_by_street.groups:
                candidates = addr_by_street.get_group(street_key).copy()
                candidates["dist"] = (candidates["house_int"] - hi).abs()
                best = candidates.loc[candidates["dist"].idxmin()]
                if best["dist"] <= FUZZY_MAX_DIST:
                    # Look up grouped row for this candidate
                    ckey = (plz_n, street_n, str(best["house_norm"]))
                    if ckey in addr_idx.index:
                        gr = addr_idx.loc[ckey]
                        cnt = int(gr["acd_count"])
                        return {
                            "ACD":           gr["ACD"],
                            "acd_count":     cnt,
                            "acd_codes":     gr["acd_codes"],
                            "match_quality": "fuzzy_nearest_house",
                            "house_distance": int(best["dist"]),
                        }
                    return {
                        "ACD":           best["ACD"],
                        "acd_count":     1,
                        "acd_codes":     best["ACD"],
                        "match_quality": "fuzzy_nearest_house",
                        "house_distance": int(best["dist"]),
                    }

        return {"ACD": None, "acd_count": 0, "acd_codes": "",
                "match_quality": "unmatched"}

    print("Running match against Fix-D grouped view...", file=sys.stderr)
    results = [match_row(row) for _, row in user_raw.iterrows()]
    matched_results = [r for r in results if r["match_quality"] != "unmatched"]
    n_total_matched  = len(matched_results)
    n_ambiguous_matched = sum(
        1 for r in matched_results if r["match_quality"] == "ambiguous_multi"
    )
    pct_ambiguous = (
        100 * n_ambiguous_matched / n_total_matched if n_total_matched else 0
    )

    print(
        f"Matched: {n_total_matched}/{n_total} "
        f"({100*n_total_matched/n_total:.1f}%)",
        file=sys.stderr
    )
    print(
        f"ambiguous_multi: {n_ambiguous_matched} "
        f"({pct_ambiguous:.1f}% of matched rows)",
        file=sys.stderr
    )

    # Collect up to 5 ambiguous examples for the report
    for i, (r, (_, row)) in enumerate(zip(results, user_raw.iterrows())):
        if r["match_quality"] == "ambiguous_multi" and len(ambiguous_examples) < 5:
            ambiguous_examples.append({
                "input_row": i + 1,
                "PLZ":       str(row[plz_col]).strip(),
                "street":    str(row[street_col]).strip(),
                "house":     str(row[house_col]).strip(),
                "acd_count": r["acd_count"],
                "acd_codes": r["acd_codes"][:80] + ("…" if len(r["acd_codes"]) > 80 else ""),
            })

# ── Find the max-acd-count example in the full Parquet ────────────────────
top5 = (
    addr_grouped
    .nlargest(5, "acd_count")
    [["plz_norm", "street_norm", "house_norm", "acd_count", "acd_codes"]]
)

# ── Write markdown report ─────────────────────────────────────────────────
lines = [
    f"# Post-D multi-unit diagnostic ({datetime.now().strftime('%Y-%m-%d')})",
    "",
    f"Source: `{PARQUET_PATH}`",
    "",
    "## ADRESSENOGD multi-unit summary",
    "",
    "| Metric | Value |",
    "|---|---:|",
    f"| Total rows in ADRESSENOGD | {n_raw:,} |",
    f"| Unique `(PLZ, street, house)` tuples | {n_unique_tuples:,} |",
    f"| Tuples with `acd_count > 1` (multi-unit) | {n_multi_tuples:,} |",
    f"| Fraction of tuples that are multi-unit | {pct_multi:.1f}% |",
    "",
]

if achen_example:
    lines += [
        "## Headline example: Achengasse 4, 1210",
        "",
        f"PLZ `{achen_example['PLZ']}`, street `{achen_example['street']}`, "
        f"house `{achen_example['house']}` → **{achen_example['acd_count']} ACDs**.",
        "",
        "```",
        achen_example["acd_codes"][:200],
        "```",
        "",
    ]

lines += [
    "## Top-5 most ambiguous addresses in ADRESSENOGD",
    "",
    "| PLZ | Street | House | acd_count | First few ACDs |",
    "|---|---|---|---:|---|",
]
for _, r in top5.iterrows():
    codes_short = r["acd_codes"][:60] + ("…" if len(r["acd_codes"]) > 60 else "")
    lines.append(
        f"| {r['plz_norm']} | {r['street_norm']} | {r['house_norm']} "
        f"| {r['acd_count']} | `{codes_short}` |"
    )
lines.append("")

if has_user_file:
    pct_ambiguous_str = f"{pct_ambiguous:.1f}"
    lines += [
        f"## Per-row match analysis (user test file: {n_total:,} rows)",
        "",
        "| Metric | Value |",
        "|---|---:|",
        f"| Total matched rows (Fix A+B) | {n_total_matched:,} |",
        f"| Rows flagged `ambiguous_multi` | {n_ambiguous_matched:,} |",
        f"| Fraction of matched rows that are ambiguous | {pct_ambiguous_str}% |",
        "",
    ]

    if ambiguous_examples:
        lines += [
            "### Ambiguous rows in the test file (first 5)",
            "",
            "| Input row | PLZ | Street | House | acd_count | ACDs (truncated) |",
            "|---:|---|---|---|---:|---|",
        ]
        for e in ambiguous_examples:
            lines.append(
                f"| {e['input_row']} | {e['PLZ']} | {e['street']} | {e['house']} "
                f"| {e['acd_count']} | `{e['acd_codes']}` |"
            )
        lines.append("")

lines += [
    "## Assessment",
    "",
    "Fix D replaces the silent arbitrary-ACD dedup with `GROUP BY + ARRAY_AGG`.",
    "The match rate is unchanged because all previously-matched rows are still",
    "matched — only the `match_quality` label changes for the ambiguous cohort.",
    "",
    f"- **{n_multi_tuples:,} unique address tuples ({pct_multi:.1f}%)** in ADRESSENOGD",
    "  have more than one valid ACD.  Previously these returned an arbitrary ACD;",
    "  now they return `acd_count` + `acd_codes` with `match_quality = ambiguous_multi`.",
]

if has_user_file:
    lines += [
        f"- **{n_ambiguous_matched:,} of {n_total_matched:,} matched rows** in the",
        f"  test file ({pct_ambiguous:.1f}%) are now flagged `ambiguous_multi`.",
    ]

lines += [
    "",
    f"Run date: {datetime.now().strftime('%Y-%m-%d %H:%M')}",
]

OUT_MD.write_text("\n".join(lines) + "\n")
print(f"\nReport written to {OUT_MD}", file=sys.stderr)
