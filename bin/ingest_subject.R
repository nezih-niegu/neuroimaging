#!/usr/bin/env Rscript
# -----------------------------------------------------------------------
# ingest_subject.R - turn one processed FreeSurfer subject into a stored
# patient + percentile report + clinical PDF. Called by step 6 of
# pipeline/neuroimaging-pipeline.sh, and usable on its own:
#
#   Rscript bin/ingest_subject.R --subject-dir $SUBJECTS_DIR/sub-001 \
#       --patient-id sub-001 --age 66 --sex M --pdf report.pdf
#
#   --subject-dir   FreeSurfer subject dir OR a folder of *stats*.txt tables
#   --api URL       submit via the running REST API instead of writing the
#                   database directly (PDF is then downloaded from the API)
# -----------------------------------------------------------------------

args <- commandArgs(trailingOnly = TRUE)
opt <- list()
i <- 1
while (i <= length(args)) {
  key <- sub("^--", "", args[i])
  if (i + 1 <= length(args) && !startsWith(args[i + 1], "--")) {
    opt[[key]] <- args[i + 1]; i <- i + 2
  } else {
    opt[[key]] <- TRUE; i <- i + 1
  }
}
`%||%` <- function(a, b) if (is.null(a)) b else a

if (is.null(opt[["subject-dir"]]) || is.null(opt[["age"]])) {
  cat("Usage: ingest_subject.R --subject-dir DIR --age YEARS [--patient-id ID] [--sex M|F]",
      "[--display-name NAME] [--notes TEXT] [--pdf FILE] [--qc-dir DIR] [--api URL]\n")
  quit(status = 2)
}

script_path <- sub("--file=", "", grep("--file=", commandArgs(), value = TRUE))
project_root <- normalizePath(file.path(dirname(normalizePath(script_path)), ".."))
subject_dir <- normalizePath(opt[["subject-dir"]], mustWork = TRUE)
setwd(project_root)
suppressPackageStartupMessages(source("global.R"))

patient_id <- opt[["patient-id"]] %||% basename(subject_dir)
age <- as.numeric(opt[["age"]])
if (is.na(age)) stop("--age must be numeric")
sex <- opt[["sex"]] %||% NA
display_name <- opt[["display-name"]] %||% patient_id
notes <- opt[["notes"]] %||% NA

subject_stats <- read_subject_stats_dir(subject_dir, patient_id)
message(sprintf("Read %d measurement tables for %s: %s", length(subject_stats), patient_id,
                paste(names(subject_stats), collapse = ", ")))

if (!is.null(opt[["api"]])) {
  api <- sub("/$", "", opt[["api"]])
  payload <- list(patient_id = patient_id, display_name = display_name, age = age,
                  sex = sex, notes = notes, stats = lapply(subject_stats, as.list))
  resp <- httr::POST(paste0(api, "/patients"),
                     body = jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null", digits = NA),
                     httr::content_type_json(), httr::timeout(120))
  if (httr::status_code(resp) != 200) {
    stop("API rejected the patient: HTTP ", httr::status_code(resp), " ",
         httr::content(resp, "text", encoding = "UTF-8"))
  }
  message("Stored via API: ", api)
  if (!is.null(opt[["pdf"]])) {
    r <- httr::GET(paste0(api, "/patients/", utils::URLencode(patient_id, reserved = TRUE), "/report.pdf"),
                   httr::write_disk(opt[["pdf"]], overwrite = TRUE), httr::timeout(120))
    if (httr::status_code(r) != 200) stop("Could not download PDF from API")
    message("PDF: ", normalizePath(opt[["pdf"]]))
  }
} else {
  models <- load_or_build_models()
  full_report <- build_full_report(subject_stats, age, models, NAMES_DIR)
  con <- db_connect(DB_PATH)
  db_upsert_patient(con, patient_id, display_name, age, sex, notes)
  db_save_report(con, patient_id, subject_stats, full_report)
  DBI::dbDisconnect(con)
  message("Stored in database: ", normalizePath(DB_PATH))
  n_out <- sum(vapply(full_report, function(d) if (nrow(d)) sum(d$out_of_range) else 0L, numeric(1)))
  n_all <- sum(vapply(full_report, nrow, integer(1)))
  message(sprintf("Regions compared: %d   outside 95%% reference interval: %d", n_all, n_out))
  if (!is.null(opt[["pdf"]])) {
    patient <- list(patient_id = patient_id, display_name = display_name, age = age,
                    sex = sex, notes = notes)
    images <- qc_images_for(patient_id, qc_dir = opt[["qc-dir"]])
    generate_pdf_report(full_report, patient, output_path = opt[["pdf"]], images = images)
    if (length(images)) message(sprintf("PDF includes %d MNE figure(s)", length(images)))
    message("PDF: ", normalizePath(opt[["pdf"]]))
  }
}
