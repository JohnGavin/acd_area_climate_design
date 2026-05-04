test_that("upload algorithm output is stable on V3 CSV (regression snapshot)", {
  skip_if_not_installed("duckdb")
  skip_on_cran()

  # Locate required files
  csv_path    <- testthat::test_path("..", "qa", "ACD_TEST_V3_no_ACD_col.csv")
  parquet_path <- system.file(
    "extdata", "addresses_2026-05-02.parquet",
    package = "acd"
  )
  if (!nzchar(parquet_path) || !file.exists(parquet_path)) {
    skip("ADRESSENOGD parquet not found — run from installed package or set addresses= manually")
  }
  if (!file.exists(csv_path)) {
    skip("V3 corpus CSV not found at tests/qa/ACD_TEST_V3_no_ACD_col.csv")
  }

  input <- utils::read.csv(
    csv_path,
    fileEncoding   = "UTF-8",
    check.names    = FALSE,
    colClasses     = "character"
  )
  # Normalise column names: remove trailing dots/slashes
  names(input) <- c("ObjektNr", "PLZ", "Strasse", "HausNr", "Stiege_RH")

  result <- run_upload_algorithm(input)

  # Snapshot the per-row summary (quality + ACD) — keep small enough to review
  snapshot_payload <- result |>
    dplyr::select(ObjektNr, PLZ, Strasse, HausNr, match_quality, ACD)

  expect_snapshot_value(snapshot_payload, style = "json2")

  # Per-quality counts as a compact stable summary
  expect_snapshot(
    result |>
      dplyr::count(match_quality) |>
      dplyr::arrange(dplyr::desc(n))
  )
})

test_that("upload algorithm gold-standard subset assertions", {
  skip("TODO #46 Tier 2: curate ~30 hand-verified gold ACDs in tests/qa/upload_algorithm_gold.csv")
})
