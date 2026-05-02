# default.R for acd package
# Generate default.nix using rix::rix()

library(rix)

r_pkgs <- c(
  # Core dependencies (from DESCRIPTION Imports)
  "sf",
  "dplyr",
  "rlang",
  "glue",
  "fs",
  "httr2",
  "cli",
  "digest",
  "tibble",

  # Suggested packages
  "leaflet",
  "DT",
  "gt",
  "knitr",
  "quarto",
  "testthat",
  "arrow",
  "duckdb",
  "duckplyr",
  "osmdata",
  "pointblank",
  "targets",

  # Validation / web scraping
  "rvest",

  # Development and documentation
  "devtools",
  "gert",
  "roxygen2",
  "rmarkdown",
  "pkgdown",
  "xml2"
)

system_pkgs <- c(
  "gdal",
  "geos",
  "glibcLocales",
  "nix",
  "proj",
  "quarto",
  "which",
  "pandoc"
)

rix(
  r_ver = "4.5.3",
  r_pkgs = r_pkgs,
  system_pkgs = system_pkgs,
  ide = "none",
  project_path = ".",
  overwrite = TRUE
)
