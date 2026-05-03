#!/usr/bin/env bash
# Post-render hook — runs after `quarto render` completes.
# Restores docs/data/ Parquet snapshots that quarto's full-site render
# strips from the output directory (issue #26).
#
# The dashboard's "remote query" card (Stage 2) and any duckplyr
# httpfs path served from docs/data/*.parquet relies on these files
# being available at the deployed gh-pages URL. Without this hook,
# every full-site render produces an HTML that points at 404'd data.
#
# Idempotent. Safe to re-run. Non-zero exit only on hard failures.

set -euo pipefail

PROJECT_ROOT="${QUARTO_PROJECT_DIR:-$(pwd)}"
SRC_DIR="$PROJECT_ROOT/inst/extdata"
DST_DIR="$PROJECT_ROOT/docs/data"

if [ ! -d "$SRC_DIR" ]; then
  echo "post-render: no inst/extdata/ — skipping data copy"
  exit 0
fi

mkdir -p "$DST_DIR"

# Copy data files committed to inst/extdata/ to docs/data/.
# Extensions covered: .parquet (Stage 2 storage), .xlsx (sample-upload demo files), .csv (lookup tables).
# Use cp -p to preserve mtime so cache headers behave.
n_copied=0
for ext in parquet xlsx csv; do
  for f in "$SRC_DIR"/*."$ext"; do
    [ -f "$f" ] || continue
    cp -p "$f" "$DST_DIR/$(basename "$f")"
    n_copied=$((n_copied + 1))
  done
done

echo "post-render: copied $n_copied data file(s) from inst/extdata/ to docs/data/"
