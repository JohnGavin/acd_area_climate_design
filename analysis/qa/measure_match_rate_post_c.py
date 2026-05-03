#!/usr/bin/env python3
"""
Post-C match-rate measurement for upload.qmd Fix C (REST API fallback).

Takes the 118 rows still unmatched after Fix A + Fix B (#37) and calls
the city's OGDAddressService REST endpoint for each, using the same
concurrency and timeout parameters as the JS implementation.

Inputs:
  - /Users/johngavin/Downloads/ACD TEST V2.xlsx  (user's 2,039-row test file)
  - /private/tmp/acd_48/docs/data/addresses_2026-05-02.parquet  (ADRESSENOGD)

Outputs:
  - analysis/qa/upload_match_rate_post_c.md  (markdown report)

REST API:
  GET https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo
      ?Address=<urlencoded>&CRS=EPSG:4326
"""

import concurrent.futures
import re
import sys
import time
import urllib.parse
import urllib.request
import json
import pandas as pd
import pyarrow.parquet as pq
from pathlib import Path
from datetime import datetime

# ── Paths ─────────────────────────────────────────────────────────────────
XLSX_PATH    = "/Users/johngavin/Downloads/ACD TEST V2.xlsx"
PARQUET_PATH = "/private/tmp/acd_48/docs/data/addresses_2026-05-02.parquet"
OUT_MD       = Path(__file__).parent / "upload_match_rate_post_c.md"
BASE_URL     = "https://data.wien.gv.at/daten/OGDAddressService.svc/GetAddressInfo"

# Match the JS parameters exactly
CONCURRENCY     = 8
MAX_CALLS       = 250
TIMEOUT_SEC     = 5
FUZZY_MAX_DIST  = 20

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
            trailing = extract_trailing_number(part)
            street_only = re.sub(r'\s*\d+\w*$', '', part).strip()
            out.append({
                "PLZ": plz,
                "street_norm": street_only.lower(),
                "house_norm":  (trailing or house).lower(),
                "composite_index": i,
                "composite_total": len(parts),
            })
        return out
    else:
        return [{
            "PLZ": plz,
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

addr = (
    addr_raw
    .sort_values(["plz_norm", "street_norm", "house_norm"])
    .drop_duplicates(subset=["plz_norm", "street_norm", "house_norm"], keep="first")
    [["plz_norm", "street_norm", "house_norm", "ACD", "SCD_NAME_STR"]]
    .rename(columns={"SCD_NAME_STR": "SCD"})
)
addr_idx = addr.set_index(["plz_norm", "street_norm", "house_norm"])

addr_numeric = addr_raw.copy()
addr_numeric["house_int"] = (
    addr_numeric["house_norm"].str.extract(r'^(\d+)').astype(float)
)
addr_numeric = addr_numeric.dropna(subset=["house_int"])
addr_by_street = addr_numeric.groupby(["plz_norm", "street_norm"])

print(f"ADRESSENOGD: {len(addr):,} unique tuples", file=sys.stderr)

# ── Load user file ────────────────────────────────────────────────────────
print("Loading user xlsx...", file=sys.stderr)
user_raw = pd.read_excel(XLSX_PATH, dtype=str).fillna("")
cols       = list(user_raw.columns)
plz_col    = detect_col(cols, ["plz","postcode","zip","postleitzahl"])
street_col = detect_col(cols, ["strasse","street","strase","str","streetname","strassename","name"])
house_col  = detect_col(cols, ["hausnr","hnr","hausnummer","nr","housenumber","number"])

print(f"User: {len(user_raw):,} rows | PLZ={plz_col!r} Street={street_col!r} House={house_col!r}",
      file=sys.stderr)

# ── Exact match ───────────────────────────────────────────────────────────
def exact_match(row):
    plz_n    = str(row[plz_col]).strip()
    street_n = str(row[street_col]).strip().lower()
    house_n  = str(row[house_col]).strip().lower()
    key = (plz_n, street_n, house_n)
    if key in addr_idx.index:
        r = addr_idx.loc[key]
        return {"ACD": r["ACD"], "SCD": r["SCD"],
                "match_quality": "exact", "house_distance": None}
    return None


def fuzzy_match(row):
    plz_n    = str(row[plz_col]).strip()
    street_n = str(row[street_col]).strip().lower()
    house_n  = str(row[house_col]).strip().lower()
    hi = leading_int(house_n)
    if hi is None:
        return None
    key = (plz_n, street_n)
    if key not in addr_by_street.groups:
        return None
    candidates = addr_by_street.get_group(key).copy()
    candidates["dist"] = (candidates["house_int"] - hi).abs()
    best = candidates.loc[candidates["dist"].idxmin()]
    if best["dist"] > FUZZY_MAX_DIST:
        return None
    return {"ACD": best["ACD"], "SCD": best.get("SCD_NAME_STR", ""),
            "match_quality": "fuzzy_nearest_house",
            "house_distance": int(best["dist"])}


def composite_match(row):
    parts = split_composite(row, plz_col, street_col, house_col)
    if len(parts) <= 1:
        return None
    results = []
    for p in parts:
        key = (p["PLZ"], p["street_norm"], p["house_norm"])
        if key in addr_idx.index:
            r = addr_idx.loc[key]
            results.append({"ACD": r["ACD"], "SCD": r["SCD"]})
        else:
            results.append(None)
    matched = [r for r in results if r is not None]
    if len(matched) == len(parts):
        mq = "split_both"
    elif matched:
        mq = "split_partial"
    else:
        return None
    return {"ACD": matched[0]["ACD"], "SCD": matched[0]["SCD"],
            "match_quality": mq, "house_distance": None}


# ── Run A+B passes ────────────────────────────────────────────────────────
print("Running exact + Fix A + Fix B passes...", file=sys.stderr)
results_ab = []
for _, row in user_raw.iterrows():
    # Try composite first (Fix B) if "/" in street
    street_val = str(row[street_col]).strip()
    if "/" in street_val:
        r = composite_match(row)
        if r:
            results_ab.append(r)
            continue

    r = exact_match(row)
    if r:
        results_ab.append(r)
        continue

    r = fuzzy_match(row)
    if r:
        results_ab.append(r)
        continue

    results_ab.append({"ACD": None, "match_quality": "unmatched",
                        "house_distance": None})

user_with_ab = user_raw.copy()
user_with_ab["match_quality_ab"] = [r["match_quality"] for r in results_ab]
user_with_ab["ACD_ab"]           = [r.get("ACD")  for r in results_ab]

unmatched_mask = user_with_ab["match_quality_ab"] == "unmatched"
unmatched_rows = user_with_ab[unmatched_mask].copy()
n_unmatched_ab = len(unmatched_rows)
n_total        = len(user_raw)
n_matched_ab   = n_total - n_unmatched_ab

print(f"A+B: {n_matched_ab}/{n_total} matched ({100*n_matched_ab/n_total:.1f}%)",
      file=sys.stderr)
print(f"Unmatched after A+B: {n_unmatched_ab}", file=sys.stderr)

# ── Fix C: REST API fallback ──────────────────────────────────────────────
calls_to_make = min(n_unmatched_ab, MAX_CALLS)
print(f"\nFix C: calling REST API for {calls_to_make} rows "
      f"(concurrency={CONCURRENCY}, timeout={TIMEOUT_SEC}s)...",
      file=sys.stderr)

rest_results   = {}   # index (in unmatched_rows) → result dict
api_errors     = []
api_rate_limit = False


def call_api(args):
    idx, row = args
    street = str(row[street_col]).strip()
    house  = str(row[house_col]).strip()
    addr_q = f"{street} {house}".strip()
    url    = f"{BASE_URL}?Address={urllib.parse.quote(addr_q)}&CRS=EPSG:4326"
    try:
        req = urllib.request.Request(url, headers={"User-Agent": "acd-qa-script/1.0"})
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEC) as resp:
            if resp.status == 429:
                return idx, None, "rate_limited"
            data = json.loads(resp.read().decode())
            features = data.get("features", [])
            if features and features[0].get("properties", {}).get("ACD"):
                p = features[0]["properties"]
                g = features[0].get("geometry", {})
                coords = (g.get("coordinates") or [None, None])
                return idx, {
                    "ACD":           p.get("ACD"),
                    "SCD":           p.get("SCD", ""),
                    "STRABS":        p.get("STRABS", ""),
                    "AdressID":      p.get("AdressID", ""),
                    "lon":           coords[0] if len(coords) > 0 else None,
                    "lat":           coords[1] if len(coords) > 1 else None,
                    "match_quality": "rest_api_fallback",
                    "rest_ranking":  p.get("Ranking", ""),
                }, None
            return idx, None, "no_match"
    except Exception as e:
        return idx, None, str(e)


# Run in batches matching JS concurrency cap
to_call   = list(enumerate(unmatched_rows.itertuples(index=False, name=None)))[:calls_to_make]
done      = 0
rest_hits = 0

t_start = time.time()
with concurrent.futures.ThreadPoolExecutor(max_workers=CONCURRENCY) as ex:
    # Wrap itertuples back to dicts
    def make_args():
        for pos, (i, row) in enumerate(
            zip(range(len(unmatched_rows)), unmatched_rows.iterrows())
        ):
            if pos >= calls_to_make:
                break
            yield pos, row[1]  # row[1] is the Series

    futures = {ex.submit(call_api, args): args[0] for args in make_args()}

    for fut in concurrent.futures.as_completed(futures):
        idx_pos, match, err = fut.result()
        done += 1
        if match:
            rest_results[idx_pos] = match
            rest_hits += 1
        elif err == "rate_limited":
            api_rate_limit = True
            api_errors.append(f"Row {idx_pos}: rate limited")
        elif err and err != "no_match":
            api_errors.append(f"Row {idx_pos}: {err}")

        if done % 10 == 0 or done == calls_to_make:
            elapsed = time.time() - t_start
            print(f"  {done}/{calls_to_make} calls done "
                  f"({rest_hits} hits, {elapsed:.1f}s elapsed)",
                  file=sys.stderr)

t_elapsed = time.time() - t_start

# ── Build final counts ─────────────────────────────────────────────────────
n_rest_matched   = rest_hits
n_rest_no_match  = calls_to_make - rest_hits - len(api_errors)
n_over_budget    = max(0, n_unmatched_ab - MAX_CALLS)
n_total_matched  = n_matched_ab + n_rest_matched
match_rate_c     = 100 * n_total_matched / n_total

print(f"\nPost-C: {n_total_matched}/{n_total} matched ({match_rate_c:.1f}%)",
      file=sys.stderr)

# ── Sample of REST-resolved rows ───────────────────────────────────────────
resolved_sample = []
unmatched_list  = list(unmatched_rows.iterrows())
for pos, result in list(rest_results.items())[:10]:
    _, row_data = unmatched_list[pos]
    resolved_sample.append({
        "PLZ":     row_data[plz_col],
        "Strasse": row_data[street_col],
        "HausNr":  row_data[house_col],
        "ACD":     result["ACD"],
        "Ranking": result.get("rest_ranking", ""),
    })

# ── Write markdown report ─────────────────────────────────────────────────
lines = [
    f"# Post-C match-rate measurement ({datetime.now().strftime('%Y-%m-%d')})",
    "",
    f"Source: `{XLSX_PATH}` ({n_total:,} rows)",
    f"Address reference: `{PARQUET_PATH}`",
    f"REST API: `{BASE_URL}`",
    f"Concurrency: {CONCURRENCY} | Max calls: {MAX_CALLS} | Timeout: {TIMEOUT_SEC}s",
    "",
    "## Headline",
    "",
    "| Approach | Matched | Total | Rate |",
    "|---|---:|---:|---:|",
    f"| Baseline (exact only, pre-#37) | 1,661 | {n_total:,} | 81.5% |",
    f"| Post-A+B (#37) | {n_matched_ab:,} | {n_total:,} | {100*n_matched_ab/n_total:.1f}% |",
    f"| **Post-A+B+C (this run)** | **{n_total_matched:,}** | **{n_total:,}** | **{match_rate_c:.1f}%** |",
    f"| Target | ≥ 2,000 | {n_total:,} | ≥ 98% |",
    "",
    "## Fix C REST API results",
    "",
    f"- Unmatched rows entering Fix C: **{n_unmatched_ab}**",
    f"- REST API calls made: **{calls_to_make}**",
    f"- Additional matches via REST: **{n_rest_matched}** ({100*n_rest_matched/n_unmatched_ab if n_unmatched_ab else 0:.1f}% of residual)",
    f"- No match from REST API: **{n_rest_no_match}**",
    f"- API errors: **{len(api_errors)}**",
    f"- Over-budget (skipped): **{n_over_budget}**",
    f"- Elapsed time for REST calls: **{t_elapsed:.1f}s**",
    "",
]

if api_rate_limit:
    lines += [
        "## ⚠ Rate limit hit",
        "",
        "The REST API returned HTTP 429 during the test run. Results represent",
        "a partial run under realistic conditions. The JS implementation uses the",
        "same concurrency and call cap — users may see similar rate limiting",
        "under heavy use.",
        "",
    ]

if api_errors:
    lines += [
        "## API errors (sample)",
        "",
    ]
    for e in api_errors[:10]:
        lines.append(f"- `{e}`")
    lines.append("")

if resolved_sample:
    lines += [
        "## Sample REST-resolved rows (first 10)",
        "",
        "| PLZ | Strasse | HausNr | ACD | Ranking |",
        "|---|---|---|---|---:|",
    ]
    for s in resolved_sample:
        lines.append(
            f"| {s['PLZ']} | {s['Strasse']} | {s['HausNr']} | `{s['ACD']}` | {s['Ranking']} |"
        )
    lines.append("")

lines += [
    "## Assessment",
    "",
]

if match_rate_c >= 98.0:
    lines.append(f"**Target REACHED** — match rate {match_rate_c:.1f}% ≥ 98%.")
else:
    lines.append(
        f"**Target NOT reached** — match rate {match_rate_c:.1f}% < 98%. "
        f"REST API recovered {n_rest_matched} of {n_unmatched_ab} residual rows."
    )

lines += [
    "",
    "## Notes",
    "",
    f"- Fix C tested at concurrency {CONCURRENCY}, max {MAX_CALLS} calls, {TIMEOUT_SEC}s timeout",
    "  — same parameters as the JS `restFallback()` function in `upload.qmd`.",
    f"- Run date: {datetime.now().strftime('%Y-%m-%d %H:%M')} UTC",
    "- See `analysis/qa/upload_match_rate_post_a_b.md` for the A+B baseline.",
    "- CORS behaviour (browser origin vs Python HTTP client) may differ; see",
    "  report section for CORS test result.",
]

OUT_MD.write_text("\n".join(lines) + "\n")
print(f"\nReport written to {OUT_MD}", file=sys.stderr)
