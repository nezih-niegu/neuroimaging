# -----------------------------------------------------------------------
# pipeline_jobs.R
#
# Lets the web service and the Shiny app drive the FreeSurfer pipeline
# (pipeline/neuroimaging-pipeline.sh):
#
#   * freesurfer_status()       - is FreeSurfer installed / licensed here?
#   * start_pipeline_job()      - launch a background run for one subject
#   * list_pipeline_jobs() / get_pipeline_job()  - progress + log tail
#   * import_freesurfer_subject() - read an already-processed subject from
#                                   SUBJECTS_DIR and compute its report
#
# A job is a folder under data/jobs/<job_id>/ holding job.json (request),
# pipeline.log (live output) and exit_code (written when it finishes), so
# job state survives app/API restarts and needs no extra services.
# -----------------------------------------------------------------------

pipeline_script <- function() normalizePath(file.path("pipeline", "neuroimaging-pipeline.sh"), mustWork = FALSE)

jobs_dir <- function() Sys.getenv("NEUROIMAGING_JOBS_DIR", unset = file.path("data", "jobs"))

processed_dir <- function() Sys.getenv("NEUROIMAGING_PROCESSED_DIR", unset = file.path("data", "processed"))

incoming_dir <- function() Sys.getenv("NEUROIMAGING_INCOMING_DIR", unset = file.path("data", "incoming"))

#' Folders the pipeline may read input from (DICOM / T1). Server-side
#' paths sent through the API must live under one of these.
allowed_input_roots <- function() {
  env <- Sys.getenv("NEUROIMAGING_INPUT_ROOTS", unset = "")
  roots <- c(incoming_dir(), default_subjects_dir(),
             if (nzchar(env)) strsplit(env, ":", fixed = TRUE)[[1]])
  roots <- roots[nzchar(roots) & dir.exists(roots)]
  unique(normalizePath(roots))
}

path_is_allowed <- function(path) {
  p <- normalizePath(path, mustWork = FALSE)
  any(vapply(allowed_input_roots(), function(r) p == r || startsWith(p, paste0(r, "/")), logical(1)))
}

valid_subject_id <- function(x) is.character(x) && length(x) == 1 && grepl("^[A-Za-z0-9._-]+$", x)

#' Environment report from pipeline/check_environment.sh --json
freesurfer_status <- function() {
  script <- file.path("pipeline", "check_environment.sh")
  out <- tryCatch(system2("bash", c(shQuote(script), "--json"), stdout = TRUE, stderr = FALSE),
                  error = function(e) character())
  st <- tryCatch(jsonlite::fromJSON(paste(out, collapse = "")), error = function(e) NULL)
  if (is.null(st)) st <- list(ready = FALSE, error = "could not run pipeline/check_environment.sh")
  st[vapply(st, is.null, logical(1))] <- list(NA)   # JSON null, not {}
  st$subjects_dir <- normalizePath(default_subjects_dir(), mustWork = FALSE)
  st
}

#' Launch the pipeline for one subject in the background
#'
#' @param subject_id patient/subject identifier
#' @param dicom_dir,t1_path input (one of them, or existing = TRUE)
#' @return the job record (list)
start_pipeline_job <- function(subject_id, dicom_dir = NULL, t1_path = NULL, existing = FALSE,
                               age = NULL, sex = NULL, threads = NULL, subregions = TRUE,
                               report = TRUE) {
  if (!valid_subject_id(subject_id)) stop("subject_id may only contain letters, digits, '.', '_' and '-'")
  if (!is.null(age)) age <- suppressWarnings(as.numeric(age))
  if (!is.null(threads)) threads <- suppressWarnings(as.integer(threads))
  n_in <- (!is.null(dicom_dir) && nzchar(dicom_dir)) + (!is.null(t1_path) && nzchar(t1_path)) + isTRUE(existing)
  if (n_in != 1) stop("Give exactly one of dicom_dir, t1_path or existing = TRUE")
  for (p in c(dicom_dir, t1_path)) {
    if (!nzchar(p)) next
    if (!file.exists(p)) stop("Input not found on the server: ", p)
    if (!path_is_allowed(p)) stop("Input must be inside one of: ", paste(allowed_input_roots(), collapse = ", "),
                                   " (set NEUROIMAGING_INPUT_ROOTS to allow more)")
  }
  if (!is.null(sex) && !(sex %in% c("M", "F", ""))) stop("sex must be M or F")
  if (!is.null(age) && !is.na(age) && (!is.numeric(age) || age <= 0 || age > 120)) stop("age must be a number of years")
  if (isTRUE(report) && (is.null(age) || is.na(age)) && is.null(dicom_dir)) {
    stop("age is required unless it can be read from DICOMs")
  }

  job_id <- paste0(format(Sys.time(), "%Y%m%d-%H%M%S"), "-", subject_id)
  jdir <- file.path(jobs_dir(), job_id)
  dir.create(jdir, recursive = TRUE, showWarnings = FALSE)
  jdir <- normalizePath(jdir)

  dir.create(default_subjects_dir(), recursive = TRUE, showWarnings = FALSE)
  out_dir <- file.path(processed_dir(), subject_id)
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  args <- c("--subject", subject_id,
            "--subjects-dir", normalizePath(default_subjects_dir()),
            "--output-dir", normalizePath(out_dir))
  if (!is.null(dicom_dir) && nzchar(dicom_dir)) args <- c(args, "--dicom", normalizePath(dicom_dir))
  if (!is.null(t1_path) && nzchar(t1_path)) args <- c(args, "--t1", normalizePath(t1_path))
  if (isTRUE(existing)) args <- c(args, "--existing")
  if (!is.null(age) && !is.na(age)) args <- c(args, "--age", as.character(age))
  if (!is.null(sex) && nzchar(sex)) args <- c(args, "--sex", sex)
  if (!is.null(threads) && !is.na(threads)) args <- c(args, "--threads", as.character(as.integer(threads)))
  if (!isTRUE(subregions)) args <- c(args, "--no-subregions")
  if (isTRUE(report)) args <- c(args, "--report")

  job <- list(job_id = job_id, subject_id = subject_id, created = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
              command = paste(c(pipeline_script(), args), collapse = " "))
  jsonlite::write_json(job, file.path(jdir, "job.json"), auto_unbox = TRUE, pretty = TRUE)

  inner <- sprintf("%s > %s 2>&1; echo $? > %s",
                   paste(shQuote(c(pipeline_script(), args)), collapse = " "),
                   shQuote(file.path(jdir, "pipeline.log")),
                   shQuote(file.path(jdir, "exit_code")))
  # setsid + nohup: the run keeps going if the app/API process restarts
  launcher <- if (nzchar(Sys.which("setsid"))) "setsid" else "nohup"
  system2(launcher, c("bash", "-c", shQuote(inner)), wait = FALSE, stdout = FALSE, stderr = FALSE)
  get_pipeline_job(job_id)
}

#' Status of one job, with the current step and the tail of its log
get_pipeline_job <- function(job_id, tail_lines = 40) {
  if (!grepl("^[A-Za-z0-9._-]+$", job_id)) stop("bad job id")
  jdir <- file.path(jobs_dir(), job_id)
  if (!dir.exists(jdir)) return(NULL)
  job <- jsonlite::read_json(file.path(jdir, "job.json"))
  log_file <- file.path(jdir, "pipeline.log")
  log <- if (file.exists(log_file)) readLines(log_file, warn = FALSE) else character()
  code_file <- file.path(jdir, "exit_code")
  code <- if (file.exists(code_file)) suppressWarnings(as.integer(readLines(code_file, warn = FALSE)[1])) else NA
  steps <- regmatches(log, regexpr("STEP [0-9]+/[0-9]+: .*?(?= ==)", log, perl = TRUE))
  job$status <- if (is.na(code)) "running" else if (code == 0) "succeeded" else "failed"
  job$exit_code <- code
  job$current_step <- if (length(steps)) sub(" ==$", "", steps[length(steps)]) else "starting"
  job$log_tail <- utils::tail(log, tail_lines)
  job
}

list_pipeline_jobs <- function() {
  if (!dir.exists(jobs_dir())) {
    return(data.frame(job_id = character(), subject_id = character(), created = character(),
                      status = character(), current_step = character()))
  }
  ids <- sort(list.dirs(jobs_dir(), recursive = FALSE, full.names = FALSE), decreasing = TRUE)
  rows <- lapply(ids, function(id) {
    j <- tryCatch(get_pipeline_job(id, tail_lines = 0), error = function(e) NULL)
    if (is.null(j)) return(NULL)
    data.frame(job_id = j$job_id, subject_id = j$subject_id, created = j$created,
               status = j$status, current_step = j$current_step, stringsAsFactors = FALSE)
  })
  rows <- Filter(Negate(is.null), rows)
  if (length(rows) == 0) {
    return(data.frame(job_id = character(), subject_id = character(), created = character(),
                      status = character(), current_step = character()))
  }
  do.call(rbind, rows)
}

#' Read a processed subject from SUBJECTS_DIR (no FreeSurfer needed)
#' @return subject_stats list, as read_subject_stats_dir()
read_processed_subject <- function(subject, subjects_dir = default_subjects_dir()) {
  if (!valid_subject_id(subject)) stop("invalid subject name")
  sdir <- file.path(subjects_dir, subject)
  if (!dir.exists(sdir)) stop("No such subject in ", subjects_dir, ": ", subject)
  read_freesurfer_subject(sdir)
}

#' Extract an uploaded .zip of DICOMs into data/incoming/<subject>/
stage_dicom_zip <- function(zip_path, subject_id) {
  if (!valid_subject_id(subject_id)) stop("invalid subject id")
  dest <- file.path(incoming_dir(), subject_id, format(Sys.time(), "%Y%m%d-%H%M%S"))
  dir.create(dest, recursive = TRUE, showWarnings = FALSE)
  files <- utils::unzip(zip_path, list = TRUE)$Name
  if (any(grepl("(^|/)\\.\\.(/|$)", files) | startsWith(files, "/"))) stop("zip contains unsafe paths")
  utils::unzip(zip_path, exdir = dest)
  normalizePath(dest)
}

# ---- MNE-Python visual QC ----------------------------------------------------

qc_dir_for <- function(subject) file.path(processed_dir(), subject, "qc")

#' Files produced by the MNE visualisation step for one subject
list_qc_files <- function(subject) {
  if (!valid_subject_id(subject)) stop("invalid subject name")
  d <- qc_dir_for(subject)
  if (!dir.exists(d)) return(character())
  list.files(d, pattern = "^mne_[A-Za-z0-9_]+\\.(png|html|json)$")
}

#' Absolute path of one QC file, or NULL if the name is not a QC file
qc_file_path <- function(subject, file) {
  if (!valid_subject_id(subject) || !grepl("^mne_[A-Za-z0-9_]+\\.(png|html|json)$", file)) return(NULL)
  p <- file.path(qc_dir_for(subject), file)
  if (file.exists(p)) normalizePath(p) else NULL
}

#' Run pipeline/visualize.sh for a processed subject (synchronous, ~5-60 s)
#' @return list(ok, output, files)
run_mne_visualization <- function(subject, three_d = TRUE, bem = FALSE) {
  if (!valid_subject_id(subject)) stop("invalid subject name")
  args <- c(normalizePath(file.path("pipeline", "visualize.sh")),
            "--subject", subject,
            "--subjects-dir", normalizePath(default_subjects_dir(), mustWork = FALSE),
            "--out-dir", normalizePath(qc_dir_for(subject), mustWork = FALSE))
  if (!isTRUE(three_d)) args <- c(args, "--no-3d")
  if (isTRUE(bem)) args <- c(args, "--bem")
  out <- suppressWarnings(system2("bash", shQuote(args), stdout = TRUE, stderr = TRUE))
  status <- if (is.null(attr(out, "status"))) 0L else attr(out, "status")
  list(ok = status == 0, output = as.character(out), files = list_qc_files(subject))
}
