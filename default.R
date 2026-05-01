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

  # Suggested packages
  "leaflet",
  "DT",
  "gt",
  "knitr",
  "quarto",
  "testthat",
  "arrow",
  "duckdb",
  "pointblank",
  "targets",

  # Development and documentation
  "devtools",
  "gert",
  "roxygen2",
  "rmarkdown",
  "pkgdown",
  "httr2",
  "xml2"
)

system_pkgs <- c(
  "gdal",
  "geos",
  "proj",
  "quarto"
)

rix(
  r_ver = "4.5.3",
  r_pkgs = r_pkgs,
  system_pkgs = system_pkgs,
  ide = "none",
  project_path = ".",
  overwrite = TRUE
)
