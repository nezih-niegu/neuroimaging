# -----------------------------------------------------------------------
# parse_freesurfer.R
#
# Generic readers for the tables produced by FreeSurfer's
# asegstats2table / aparcstats2table / quantifyHippocampalSubfields.sh /
# quantifyBrainstemStructures.sh commands (see legacy/recon_report.sh).
#
# Every one of those tools writes a rectangular, whitespace/tab separated
# table where the FIRST COLUMN identifies the subject and every other
# column is a measurement (volume, area or thickness) for one region.
# These functions turn that into a tidy, subject-keyed data.frame so the
# rest of the app never has to know about FreeSurfer's file formats.
# -----------------------------------------------------------------------

#' Read one FreeSurfer stats table (aseg or aparc) into a tidy data.frame
#'
#' @param path path to a *.txt table produced by asegstats2table /
#'   aparcstats2table
#' @param region one of "lh","rh","seg" (aseg = subcortical)
#' @param metric one of "vol","area","thick"
#' @return data.frame with a `subject_id` column plus one column per region
read_fs_table <- function(path, region, metric) {
  df <- utils::read.delim(path, sep = "\t", check.names = FALSE,
                           stringsAsFactors = FALSE)

  colnames(df)[1] <- "subject_id"
  df$subject_id <- trimws(as.character(df$subject_id))

  # Drop freesurfer-computed summary columns that are not per-region
  # measurements (e.g. eTIV, BrainSegVolNotVent, MeanThickness, NumVert)
  drop_cols <- grep("BrainSeg|eTIV|MaskVol|SupraTentorial|SurfaceHoles|WhiteSurfArea|MeanThickness$|NumVert$",
                     colnames(df), value = TRUE, ignore.case = TRUE)
  keep <- setdiff(colnames(df), drop_cols)
  df <- df[, keep, drop = FALSE]

  attr(df, "region") <- region
  attr(df, "metric") <- metric
  df
}

#' Read a hippocampal-subfield or brainstem-structures table
#'
#' quantifyHippocampalSubfields.sh / quantifyBrainstemStructures.sh both
#' write a single space-separated table with a "Subject" column.
read_fs_space_table <- function(path, region, metric = "vol") {
  df <- utils::read.delim(path, sep = " ", check.names = FALSE,
                           stringsAsFactors = FALSE)
  colnames(df)[1] <- "subject_id"
  df$subject_id <- trimws(as.character(df$subject_id))
  attr(df, "region") <- region
  attr(df, "metric") <- metric
  df
}

#' Read every stats table for ONE subject's output directory
#'
#' Mirrors the files recon_report.sh produces for a subject (lh/rh x
#' vol/area/thick, aseg vol, hippo vol, brainstem vol) and returns a
#' single named list keyed "region_metric" -> named numeric vector.
#'
#' @param subject_dir directory containing that subject's FreeSurfer
#'   *stats2table* output (as created by legacy/recon_report.sh)
#' @param subject_id   subject identifier as it appears in the tables
#'   (defaults to the directory's basename)
read_subject_stats_dir <- function(subject_dir, subject_id = basename(subject_dir)) {
  file_for <- function(pattern) {
    hits <- list.files(subject_dir, pattern = pattern, full.names = TRUE)
    if (length(hits) == 0) return(NA_character_)
    hits[1]
  }

  spec <- list(
    lh_vol   = list(region = "lh",  metric = "vol",   file = file_for("lhaparc_vol.*\\.txt$")),
    rh_vol   = list(region = "rh",  metric = "vol",   file = file_for("rhaparc_vol.*\\.txt$")),
    lh_thick = list(region = "lh",  metric = "thick", file = file_for("lhaparc_thick.*\\.txt$")),
    rh_thick = list(region = "rh",  metric = "thick", file = file_for("rhaparc_thick.*\\.txt$")),
    lh_area  = list(region = "lh",  metric = "area",  file = file_for("lhaparc_area.*\\.txt$")),
    rh_area  = list(region = "rh",  metric = "area",  file = file_for("rhaparc_area.*\\.txt$")),
    seg_vol  = list(region = "seg", metric = "vol",   file = file_for("asegstats_vol.*\\.txt$"))
  )

  out <- list()
  for (nm in names(spec)) {
    s <- spec[[nm]]
    if (is.na(s$file)) next
    tbl <- read_fs_table(s$file, s$region, s$metric)
    out[[nm]] <- extract_subject_row(tbl, subject_id)
  }

  hippo_file <- file_for("hipposubfield_vol.*\\.txt$")
  if (!is.na(hippo_file)) {
    tbl <- read_fs_space_table(hippo_file, "hippo")
    out[["hippo_vol"]] <- extract_subject_row(tbl, subject_id)
  }

  brainstem_file <- file_for("brainstemstruct_vol.*\\.txt$")
  if (!is.na(brainstem_file)) {
    tbl <- read_fs_space_table(brainstem_file, "brainstem")
    out[["brainstem_vol"]] <- extract_subject_row(tbl, subject_id)
  }

  out
}

#' Pull a single subject's row of measurements out of a stats table
#'
#' If `subject_id` is not found and the table only has one data row (the
#' common case for a freshly processed single new patient), that row is
#' used instead - this lets a clinician run one subject's stats file
#' straight through the pipeline without renaming anything.
extract_subject_row <- function(tbl, subject_id) {
  row <- tbl[tbl$subject_id == subject_id, , drop = FALSE]
  if (nrow(row) == 0) {
    if (nrow(tbl) == 1) {
      row <- tbl
    } else {
      stop(sprintf(
        "Subject '%s' not found in stats table and table has %d rows (ambiguous).",
        subject_id, nrow(tbl)))
    }
  }
  vals <- as.numeric(row[1, setdiff(colnames(row), "subject_id")])
  names(vals) <- setdiff(colnames(row), "subject_id")
  vals[!is.na(vals)]
}
