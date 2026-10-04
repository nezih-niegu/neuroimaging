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
# a new batch is added. Here we match generically but strictly:
#
#   * every demographics CSV belongs to a cohort, taken from the start of
#     its file name (PPMI_..., ADNI_..., ICBM_...);
#   * if a FreeSurfer subject_id names a cohort (e.g. "PPMI_3188_MR_...",
#     "ICBM_MNI_0103_..."), only that cohort's demographics are searched;
#   * the demographics ID must appear as a whole token of the subject_id,
#     i.e. bounded by non-alphanumerics: "3188" matches
#     "PPMI_3188_MR_SAG" but NOT "..._S31880_..." ; ADNI "022_S_0096"
#     matches "ADNI_022_S_0096_MR_...".
#
# (An earlier version used plain substring matching across all cohorts,
# which gave some ICBM scans the age of an unrelated PPMI subject whose
# short numeric ID happened to occur inside the ICBM scan ID.)
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
    if (nrow(d) == 0) next   # e.g. a template whose ages aren't filled in yet
    d$source_db <- sub("_[0-9].*$", "", basename(f))
    d$cohort <- toupper(sub("[^A-Za-z0-9].*$", "", basename(f)))
    rows[[f]] <- d
  }
  if (length(rows) == 0) {
    stop("No usable demographics CSVs (needing 'Subject' and 'Age' columns) found under ", reference_dir)
  }
  out <- do.call(rbind, rows)
  rownames(out) <- NULL
  out[!duplicated(paste(out$cohort, out$Subject)), ]
}

#' The cohort a FreeSurfer subject_id belongs to, if it names one of the
#' known cohorts as a token (e.g. "ICBM" in ".../ICBM_MNI_0103_MRI_..."),
#' else NA
subject_cohort <- function(subject_id, cohorts) {
  base <- basename(subject_id)
  hit <- cohorts[vapply(cohorts, token_match, logical(1), x = base)]
  if (length(hit) == 1) hit else NA_character_
}

#' TRUE if `id` occurs in `x` as a whole token: every occurrence is checked
#' (literal, case-insensitive) for non-alphanumeric characters on both sides
token_match <- function(id, x) {
  if (!nzchar(id)) return(FALSE)
  xl <- tolower(x); il <- tolower(id)
  pos <- gregexpr(il, xl, fixed = TRUE)[[1]]
  if (pos[1] == -1) return(FALSE)
  for (p in pos) {
    before <- if (p > 1) substr(xl, p - 1, p - 1) else ""
    after_i <- p + nchar(il)
    after <- if (after_i <= nchar(xl)) substr(xl, after_i, after_i) else ""
    if (!grepl("[a-z0-9]", before) && !grepl("[a-z0-9]", after)) return(TRUE)
  }
  FALSE
}

#' Match one FreeSurfer subject_id against a demographics table by substring
#'
#' @return the matching demographics row (1 row) or NULL
match_demographics <- function(subject_id, demo) {
  base <- basename(subject_id)
  cohort <- subject_cohort(base, unique(demo$cohort))
  cand <- if (!is.na(cohort)) demo[demo$cohort == cohort, , drop = FALSE] else demo
  if (nrow(cand) == 0) return(NULL)
  ok <- vapply(cand$Subject, token_match, logical(1), x = base, USE.NAMES = FALSE)
  if (!any(ok)) return(NULL)
  hits <- cand[ok, , drop = FALSE]
  # prefer the longest (most specific) matching ID if several match
  hits[which.max(nchar(hits$Subject)), , drop = FALSE]
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
    "hippo vol" = "hippo\\.txt$|batch.*_hippo\\.txt$|hipposubfield_vol.*\\.txt$",
    "brainstem vol" = "brainstem\\.txt$|batch.*_brainstem\\.txt$|brainstemstruct_vol.*\\.txt$",
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

#' Coverage report of the reference cohorts: for every cohort, how many
#' scanned subjects are in the stats tables and how many of them could be
#' given an age from a demographics CSV (only those are used in the models).
#'
#' @return list(summary = data.frame per cohort, unmatched = data.frame of
#'   subjects without demographics, demographics_files = character)
reference_summary <- function(reference_dir = default_reference_dir(),
                              cohorts = c("ICBM", "PPMI", "ADNI")) {
  demo <- tryCatch(load_reference_demographics(reference_dir), error = function(e) NULL)
  demo_files <- list.files(reference_dir, pattern = "\\.csv$", recursive = TRUE)
  known <- unique(c(cohorts, if (!is.null(demo)) demo$cohort))

  ids <- character(); files_of <- character()
  for (rm in list(c("lh", "vol"), c("rh", "vol"), c("lh", "thick"), c("rh", "thick"),
                  c("lh", "area"), c("rh", "area"), c("seg", "vol"),
                  c("hippo", "vol"), c("brainstem", "vol"))) {
    for (f in find_stats_tables(reference_dir, rm[1], rm[2])) {
      reader <- if (rm[1] %in% c("hippo", "brainstem")) read_fs_space_table else read_fs_table
      tbl <- tryCatch(reader(f, rm[1], rm[2]), error = function(e) NULL)
      if (is.null(tbl)) next
      ids <- c(ids, tbl$subject_id)
      files_of <- c(files_of, rep(f, nrow(tbl)))
    }
  }
  keep <- !duplicated(basename(ids))
  ids <- ids[keep]; files_of <- files_of[keep]
  if (length(ids) == 0) {
    return(list(summary = data.frame(), unmatched = data.frame(), demographics_files = demo_files))
  }
  coh <- vapply(ids, subject_cohort, character(1), cohorts = known, USE.NAMES = FALSE)
  coh[is.na(coh)] <- "(unknown)"
  has_age <- if (is.null(demo)) rep(FALSE, length(ids)) else
    vapply(ids, function(x) !is.null(match_demographics(x, demo)), logical(1), USE.NAMES = FALSE)

  cs <- sort(unique(c(coh, known)))
  summary <- data.frame(
    cohort = cs,
    subjects_in_tables = vapply(cs, function(c) sum(coh == c), integer(1)),
    with_age_used = vapply(cs, function(c) sum(coh == c & has_age), integer(1)),
    without_age_ignored = vapply(cs, function(c) sum(coh == c & !has_age), integer(1)),
    demographics_rows = vapply(cs, function(c) if (is.null(demo)) 0L else sum(demo$cohort == c), integer(1)),
    stringsAsFactors = FALSE, row.names = NULL)
  unmatched <- data.frame(cohort = coh[!has_age], subject_id = basename(ids[!has_age]),
                          table = sub(paste0("^", normalizePath(reference_dir), "/?"), "",
                                      normalizePath(files_of[!has_age])),
                          stringsAsFactors = FALSE)
  list(summary = summary, unmatched = unmatched, demographics_files = demo_files)
}
