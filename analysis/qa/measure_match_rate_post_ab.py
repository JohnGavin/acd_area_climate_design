#!/usr/bin/env python3
"""
Post-A+B match-rate measurement for upload.qmd algorithm.

Reproduces the JS fuzzy (Fix A) + composite-split (Fix B) logic in Python.
Runs against:
  - /Users/johngavin/Downloads/ACD TEST V2.xlsx  (user's 2,039-row test file)
  - /private/tmp/acd_37/docs/data/addresses_2026-05-02.parquet  (ADRESSENOGD)

Outputs a report to analysis/qa/upload_match_rate_post_a_b.md
"""

import re
import sys
import pandas as pd
import pyarrow.parquet as pq

XLSX_PATH    = "/Users/johngavin/Downloads/ACD TEST V2.xlsx"
PARQUET_PATH = "/private/tmp/acd_37/docs/data/addresses_2026-05-02.parquet"
FUZZY_MAX_DISTANCE = 20

# ── Load ADRESSENOGD ──────────────────────────────────────────────────────
print("Loading ADRESSENOGD Parquet...", file=sys.stderr)
addr_raw = pq.read_table(PARQUET_PATH).to_pandas()

# Normalise keys (mirror the DuckDB view)
addr_raw["street_norm"] = addr_raw["NAME_STR"].str.lower().str.strip()
addr_raw["house_norm"]  = addr_raw["NAME_ONR"].str.lower().str.strip()
addr_raw["plz_norm"]    = addr_raw["PLZ"].astype(str)

# Dedup on (plz, street, house) — same as current upload logic
addr = (
    addr_raw
    .sort_values(["plz_norm", "street_norm", "house_norm"])
    .drop_duplicates(subset=["plz_norm", "street_norm", "house_norm"], keep="first")
    [["plz_norm", "street_norm", "house_norm", "ACD", "SCD_NAME_STR"]]
)
addr = addr.rename(columns={"SCD_NAME_STR": "SCD"})

# Index for fast exact lookup
addr_idx = addr.set_index(["plz_norm", "street_norm", "house_norm"])

# Index (plz, street) for fuzzy lookup — only rows with numeric house leading digit
addr_numeric = addr_raw.copy()
addr_numeric["house_int"] = addr_numeric["house_norm"].str.extract(r'^(\d+)').astype(float)
addr_numeric = addr_numeric.dropna(subset=["house_int"])
addr_by_street = addr_numeric.groupby(["plz_norm", "street_norm"])

print(f"ADRESSENOGD: {len(addr):,} unique (PLZ, street, house) tuples", file=sys.stderr)

# ── Load user file ────────────────────────────────────────────────────────
print("Loading user xlsx...", file=sys.stderr)
user_raw = pd.read_excel(XLSX_PATH, dtype=str).fillna("")

# Auto-detect columns (same logic as JS autoDetect)
def detect_col(cols, keys):
    for c in cols:
        if re.sub(r'[^a-z]', '', c.lower()) in keys:
            return c
    return cols[0]

cols = list(user_raw.columns)
plz_col    = detect_col(cols, ["plz","postcode","zip","postleitzahl"])
street_col = detect_col(cols, ["strasse","street","strase","str","streetname","strassename","name"])
house_col  = detect_col(cols, ["hausnr","hnr","hausnummer","nr","housenumber","number"])

print(f"User file: {len(user_raw):,} rows  |  PLZ={plz_col!r}, Street={street_col!r}, House={house_col!r}", file=sys.stderr)

# ── Fix B: Composite-street splitter ─────────────────────────────────────
def extract_trailing_number(s):
    m = re.search(r'(\d+\w*)$', s.strip())
    return m.group(1) if m else None

def split_composite(row):
    """Return list of (plz_norm, street_norm, house_norm, composite_index, composite_total)"""
    plz    = str(row[plz_col]).strip()
    street = str(row[street_col]).strip()
    house  = str(row[house_col]).strip()

    if "/" in street:
        parts = [p.strip() for p in street.split("/") if p.strip()]
        out = []
        for i, part in enumerate(parts):
            trailing = extract_trailing_number(part)
            street_only = re.sub(r'\s*\d+\w*$', '', part).strip()
            h = (trailing or house).lower()
            out.append((plz, street_only.lower(), h, i, len(parts)))
        return out
    else:
        return [(plz, street.lower(), house.lower(), 0, 1)]

# ── Exact join ────────────────────────────────────────────────────────────
results = []  # one dict per original row

for idx, row in user_raw.iterrows():
    attempts = split_composite(row)

    matched_parts = []
    for (plz, sn, hn, ci, ct) in attempts:
        key = (plz, sn, hn)
        if key in addr_idx.index:
            hit = addr_idx.loc[key]
            if isinstance(hit, pd.DataFrame):
                hit = hit.iloc[0]
            matched_parts.append({
                "composite_index": ci,
                "ACD": hit["ACD"],
                "SCD": hit["SCD"],
                "match_quality": "exact"
            })
        else:
            matched_parts.append({
                "composite_index": ci,
                "ACD": None,
                "SCD": None,
                "match_quality": "unmatched"
            })

    results.append({
        "orig_idx":  idx,
        "plz":       str(row[plz_col]).strip(),
        "street":    str(row[street_col]).strip(),
        "house":     str(row[house_col]).strip(),
        "attempts":  attempts,
        "matched":   matched_parts
    })

# ── Fix A: Fuzzy fallback ─────────────────────────────────────────────────
def extract_leading_int(s):
    m = re.match(r'^(\d+)', str(s))
    return int(m.group(1)) if m else None

def fuzzy_fallback(plz, street_norm, house_norm):
    """Return (ACD, SCD, distance) or None if not found / exceeds max."""
    user_int = extract_leading_int(house_norm)
    if user_int is None:
        return None
    key = (plz, street_norm)
    if key not in addr_by_street.groups:
        return None
    group = addr_by_street.get_group(key).copy()
    group["dist"] = (group["house_int"] - user_int).abs()
    best = group.nsmallest(1, "dist").iloc[0]
    dist = int(best["dist"])
    if dist > FUZZY_MAX_DISTANCE:
        return None
    return (best["ACD"], best.get("SCD_NAME_STR", ""), dist)

for r in results:
    attempts = r["attempts"]
    matched  = r["matched"]

    # Only apply fuzzy to non-composite unmatched rows (composite_total == 1)
    if len(attempts) == 1 and matched[0]["match_quality"] == "unmatched":
        plz, sn, hn, _, _ = attempts[0]
        hit = fuzzy_fallback(plz, sn, hn)
        if hit:
            acd, scd, dist = hit
            matched[0] = {
                "composite_index":  0,
                "ACD":              acd,
                "SCD":              scd,
                "house_distance":   dist,
                "match_quality":    "fuzzy_nearest_house"
            }

# ── Aggregate per original row ────────────────────────────────────────────
def aggregate_row(r):
    matched = r["matched"]
    ct = len(r["attempts"])

    if ct == 1:
        m = matched[0]
        return {
            "ACD":           m["ACD"] or "",
            "SCD":           m["SCD"] or "",
            "house_distance": m.get("house_distance", ""),
            "acd_b":         "",
            "match_quality": m["match_quality"]
        }

    # Composite
    p0 = next((m for m in matched if m["composite_index"] == 0), None)
    p1 = next((m for m in matched if m["composite_index"] == 1), None)
    m0 = bool(p0 and p0["ACD"])
    m1 = bool(p1 and p1["ACD"])

    if m0 and m1:   q = "split_both"
    elif m0 or m1:  q = "split_partial"
    else:           q = "unmatched"

    primary = (p0 if m0 else p1) or p0 or {}
    return {
        "ACD":           (primary.get("ACD") or ""),
        "SCD":           (primary.get("SCD") or ""),
        "house_distance": "",
        "acd_b":          ((p1 or {}).get("ACD") or "") if m1 else "",
        "match_quality":  q
    }

agg = [aggregate_row(r) for r in results]

# ── Compute summary stats ──────────────────────────────────────────────────
total         = len(agg)
n_exact       = sum(1 for a in agg if a["match_quality"] == "exact")
n_fuzzy       = sum(1 for a in agg if a["match_quality"] == "fuzzy_nearest_house")
n_split_both  = sum(1 for a in agg if a["match_quality"] == "split_both")
n_split_part  = sum(1 for a in agg if a["match_quality"] == "split_partial")
n_unmatched   = sum(1 for a in agg if a["match_quality"] == "unmatched")
n_matched     = n_exact + n_fuzzy + n_split_both + n_split_part

pct_total     = round(100 * n_matched / total, 1)
pct_exact     = round(100 * n_exact    / total, 1)
pct_fuzzy     = round(100 * n_fuzzy    / total, 1)
pct_split_b   = round(100 * n_split_both  / total, 1)
pct_split_p   = round(100 * n_split_part  / total, 1)
pct_unmatched = round(100 * n_unmatched   / total, 1)

# ── Write report ──────────────────────────────────────────────────────────
report = f"""# Post-A+B match-rate measurement (2026-05-01)

Source: `{XLSX_PATH}` ({total:,} rows)
Address reference: `{PARQUET_PATH}` ({len(addr):,} unique tuples)
Algorithm: upload.qmd JS logic reproduced in Python (Fix A + Fix B active)

## Headline

| Approach | Matched | Total | Rate |
|---|---:|---:|---:|
| Baseline (exact only, pre-#37) | 1,661 | 2,039 | 81.5% |
| **Post-A+B (this run)** | **{n_matched:,}** | **{total:,}** | **{pct_total}%** |
| Target | ≥ 1,897 | 2,039 | ≥ 93% |

## Breakdown by match quality

| match_quality | Count | % of total |
|---|---:|---:|
| `exact` | {n_exact:,} | {pct_exact}% |
| `fuzzy_nearest_house` (Fix A) | {n_fuzzy:,} | {pct_fuzzy}% |
| `split_both` (Fix B) | {n_split_both:,} | {pct_split_b}% |
| `split_partial` (Fix B) | {n_split_part:,} | {pct_split_p}% |
| `unmatched` | {n_unmatched:,} | {pct_unmatched}% |

## Assessment

{"Target REACHED — match rate " + str(pct_total) + "% >= 93%." if pct_total >= 93 else "Target NOT YET reached — " + str(pct_total) + "% < 93%. See failure modes below for next steps."}

## Notes

- Fix A (fuzzy nearest house): recovers rows where the exact house number is absent from ADRESSENOGD
  but the street IS present.  Distance capped at {FUZZY_MAX_DISTANCE}.
- Fix B (composite split): rows where `Strasse` contains `/` are split into two sub-attempts;
  both, one, or neither side may match.
- Remaining unmatched ({n_unmatched:,} rows, {pct_unmatched}%) include: pure Schrebergarten parcel
  addresses, streets genuinely absent from ADRESSENOGD, and empty house numbers.
- Fix C (REST API fallback) and Fix D (multi-unit dedup) tracked as separate issues.
"""

out_path = "/private/tmp/acd_37/analysis/qa/upload_match_rate_post_a_b.md"
with open(out_path, "w") as f:
    f.write(report)

print(report)
print(f"\nReport written to {out_path}", file=sys.stderr)
