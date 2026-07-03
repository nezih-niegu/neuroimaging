# -----------------------------------------------------------------------
# reference_data.R
#
# Re-implements the "join the batches together" half of
# legacy/python_scripts/batches_joinsANDlms.py: it walks the reference
# batches directory (ICBM / PPMI / ADNI control scans, already processed
# by legacy/recon_report.sh), reads every stats table it finds, and joins
# each subject's measurements to their age/sex from whichever demographics
# CSV is available.
#
# The original python code matched subjects to demographics with a series
# of hand-written, batch-specific substr() calls. That breaks the moment
# a new batch is added. Here we match generically: a demographic row's ID
# is considered a match for a stats-table row if that ID occurs as a
# substring of the FreeSurfer subject_id (e.g. demographics Subject
# "3188" matches stats subject_id "PPMI_3188_MR_SAG_MPRAGE_GRAPPA"; ADNI
# demographics Subject "022_S_0096" matches "ADNI_022_S_0096_MR_...").
# -----------------------------------------------------------------------

#' Load and stack every demographics CSV under the reference data directory
#'
#' Any CSV with at least "Subject" and "Age" columns is used. Extra
#' columns (Sex, Group, DB label, ...) are kept when present.
#'
#' @param reference_dir root of the reference batches tree
load_reference_demographics <- function(reference_dir) {
  csvs <- list.files(reference_dir, pattern = "\\.csv$", recursive = TRUE, full.names = TRUE)
  rows <- list()
  for (f in csvs) {
    d <- tryCatch(utils::read.csv(f, stringsAsFactors = FALSE), error = function(e) NULL)
    if (is.null(d)) next
    if (!all(c("Subject", "Age") %in% colnames(d))) next
    d <- d[, intersect(c("Subject", "Age", "Sex", "Group"), colnames(d)), drop = FALSE]
    d$Subject <- as.character(d$Subject)
    d$Age <- suppressWarnings(as.numeric(d$Age))
    d <- d[!is.na(d$Age) & nchar(d$Subject) > 0, , drop = FALSE]
    d$source_db <- sub("_[0-9].*$", "", basename(f))
    rows[[f]] <- d
  }
  if (length(rows) == 0) {
    stop("No usable demographics CSVs (needing 'Subject' and 'Age' columns) found under ", reference_dir)
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out[!duplicated(out$Subject), ]
}

#' Match one FreeSurfer subject_id against a demographics table by substring
#'
#' @return the matching demographics row (1 row) or NULL
match_demographics <- function(subject_id, demo) {
  hit <- demo$Subject[vapply(demo$Subject, function(id) grepl(id, subject_id, fixed = TRUE), logical(1))]
  if (length(hit) == 0) return(NULL)
  # prefer the longest (most specific) matching ID if several match
  best <- hit[which.max(nchar(hit))]
  demo[demo$Subject == best, , drop = FALSE][1, ]
}

#' Find every stats table of a given region/metric under the reference tree
find_stats_tables <- function(reference_dir, region, metric) {
  pattern <- switch(
    paste(region, metric),
    "lh vol"   = "lhaparc_vol.*\\.txt$|lhaparc_ICBM\\.txt$",
    "rh vol"   = "rhaparc_vol.*\\.txt$|rhaparc_ICBM\\.txt$",
    "lh thick" = "lhaparc_thick.*\\.txt$",
    "rh thick" = "rhaparc_thick.*\\.txt$",
    "lh area"  = "lhaparc_area.*\\.txt$",
    "rh area"  = "rhaparc_area.*\\.txt$",
    "seg vol"  = "asegstats_vol.*\\.txt$|segstats_ICBM\\.txt$",
    "hippo vol" = "hippo\\.txt$|batch.*_hippo\\.txt$",
    "brainstem vol" = "brainstem\\.txt$|batch.*_brainstem\\.txt$",
    stop("Unknown region/metric combination: ", region, " / ", metric)
  )
  list.files(reference_dir, pattern = pattern, recursive = TRUE, full.names = TRUE)
}

#' Build the long-format reference dataset for one region/metric
#'
#' Equivalent to `batches_fusion` in the legacy python script: every
#' control subject's per-region measurements, joined to their age.
#'
#' @param reference_dir root of the reference batches tree
#' @param region  "lh","rh","seg","hippo","brainstem"
#' @param metric  "vol","area","thick"
#' @param demo    demographics table from load_reference_demographics()
#' @return data.frame with columns: column (region/measure name), age,
#'   sex, value, subject_id, source_db
build_reference_long <- function(reference_dir, region, metric, demo) {
  files <- find_stats_tables(reference_dir, region, metric)
  if (length(files) == 0) {
    warning("No stats tables found for ", region, "/", metric)
    return(data.frame())
  }

  space_sep <- region %in% c("hippo", "brainstem")
  reader <- if (space_sep) read_fs_space_table else read_fs_table

  all_long <- list()
  for (f in files) {
    tbl <- tryCatch(reader(f, region, metric),
                     error = function(e) { warning("Failed to read ", f, ": ", conditionMessage(e)); NULL })
    if (is.null(tbl) || nrow(tbl) == 0) next

    measure_cols <- setdiff(colnames(tbl), "subject_id")
    for (i in seq_len(nrow(tbl))) {
      sid <- tbl$subject_id[i]
      demo_row <- match_demographics(sid, demo)
      if (is.null(demo_row)) next
      vals <- suppressWarnings(as.numeric(tbl[i, measure_cols]))
      keep <- !is.na(vals)
      if (!any(keep)) next
      all_long[[length(all_long) + 1]] <- data.frame(
        column     = measure_cols[keep],
        age        = demo_row$Age,
        sex        = if ("Sex" %in% colnames(demo_row)) demo_row$Sex else NA,
        value      = vals[keep],
        subject_id = sid,
        source_db  = demo_row$source_db,
        stringsAsFactors = FALSE
      )
    }
  }
  if (length(all_long) == 0) return(data.frame())
  do.call(rbind, all_long)
}
