#!/usr/bin/env Rscript
# Write the legacy-format per-subject stats tables (asegstats_vol.txt,
# ?haparc_{vol,thick,area}.txt, hipposubfield_vol.txt,
# brainstemstruct_vol.txt) straight from a FreeSurfer subject directory.
# Fallback for step 5 of pipeline/neuroimaging-pipeline.sh.
#
#   Rscript bin/export_tables.R <subject_dir> <subject_id> <output_dir>
args <- commandArgs(trailingOnly = TRUE)
if (length(args) != 3) {
  cat("Usage: export_tables.R <subject_dir> <subject_id> <output_dir>\n"); quit(status = 2)
}
script_path <- sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))
subject_dir <- normalizePath(args[1], mustWork = TRUE)
out_dir <- normalizePath(args[3], mustWork = FALSE)
setwd(normalizePath(file.path(dirname(normalizePath(script_path)), "..")))
suppressPackageStartupMessages(source("global.R"))
written <- export_subject_tables(read_freesurfer_subject(subject_dir), args[2], out_dir)
cat(paste("wrote", written), sep = "\n")
