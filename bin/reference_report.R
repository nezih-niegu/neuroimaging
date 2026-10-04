#!/usr/bin/env Rscript
# Show which reference-cohort subjects (ICBM / PPMI / ADNI / ...) the models
# can use, and which are ignored because no age was found for them.
#   Rscript bin/reference_report.R [--unmatched] [--rebuild]
args <- commandArgs(trailingOnly = TRUE)
script_path <- sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))
setwd(normalizePath(file.path(dirname(normalizePath(script_path)), "..")))
suppressPackageStartupMessages(source("global.R"))
cat("Reference folder:", normalizePath(REFERENCE_DIR), "\n\n")
r <- reference_summary(REFERENCE_DIR)
cat("Demographics files:\n"); cat(paste0("  ", r$demographics_files, collapse = "\n"), "\n\n")
print(r$summary, row.names = FALSE)
if (nrow(r$unmatched)) {
  cat(sprintf("\n%d scanned subject(s) have no age and are NOT used.", nrow(r$unmatched)),
      "Add them to a <COHORT>_*.csv with Subject + Age columns.\n")
  if ("--unmatched" %in% args) print(r$unmatched, row.names = FALSE)
  else cat("Run with --unmatched to list them.\n")
}
if ("--rebuild" %in% args) { cat("\nRebuilding models...\n"); invisible(load_or_build_models(force_rebuild = TRUE)) }
