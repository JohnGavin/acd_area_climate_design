test_that("validate_deploy returns a tibble with expected columns", {
  skip_on_cran()
  skip_if(
    tryCatch(
      {
        httr2::request("https://johngavin.github.io") |>
          httr2::req_timeout(5) |>
          httr2::req_perform()
        FALSE
      },
      error = function(e) TRUE
    ),
    "offline"
  )

  res <- validate_deploy()

  expect_s3_class(res, "tbl_df")
  expect_true(all(c("url", "http_status", "verdict") %in% names(res)))
  expect_equal(nrow(res), 3L)
  expect_true(all(res$http_status == 200L),
              info = "All pages must return HTTP 200")
  expect_true(all(res$verdict %in% c("PASS", "WARN", "FAIL")))
})

test_that("all deployed pages pass validation", {
  skip_on_cran()
  skip_if(
    tryCatch(
      {
        httr2::request("https://johngavin.github.io") |>
          httr2::req_timeout(5) |>
          httr2::req_perform()
        FALSE
      },
      error = function(e) TRUE
    ),
    "offline"
  )

  res <- validate_deploy()

  failed <- res[res$verdict == "FAIL", ]
  expect_equal(
    nrow(failed), 0L,
    info = paste(
      "Failed pages:",
      if (nrow(failed) > 0L) paste(failed$url, collapse = ", ") else "none"
    )
  )
})
