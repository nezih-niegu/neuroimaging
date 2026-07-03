# -----------------------------------------------------------------------
# plumber.R - REST API for the neuroimaging normative-reference service.
#
# Run with:  Rscript run_api.R   (see that file for the port)
#
# This is a standalone web service: the Shiny app (app.R) is one client
# of it, talking over HTTP just like any external system (e.g. a LIS/EHR
# integration) could. It owns all reads/writes to the patient database.
# -----------------------------------------------------------------------

source("global.R")

MODELS <- load_or_build_models()

#* @apiTitle Neuroimaging Normative Reference API
#* @apiDescription Computes percentile-for-age brain-region reports for a
#*   new patient against the ICBM/PPMI/ADNI control reference models, and
#*   stores every patient + report in the shared SQLite database.

#* Health check
#* @get /health
function() {
  list(status = "ok", time = as.character(Sys.time()),
       regions_loaded = names(MODELS))
}

#* Rebuild the reference regression models from the batches on disk
#* @post /models/rebuild
function() {
  log_lines <- c()
  res <- build_reference_models(REFERENCE_DIR, MODELS_PATH,
                                 progress = function(m) log_lines <<- c(log_lines, m))
  MODELS <<- res$models
  list(status = "ok", log = log_lines,
       fit_summary = res$fit_log)
}

#* List every patient in the database
#* @get /patients
function() {
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  db_list_patients(con)
}

#* Get one patient's demographics and their most recent report
#* @get /patients/<patient_id>
function(patient_id, res) {
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  patient <- db_get_patient(con, patient_id)
  if (nrow(patient) == 0) {
    res$status <- 404
    return(list(error = paste("No such patient:", patient_id)))
  }
  list(patient = patient, report = db_get_report(con, patient_id))
}

#* Delete a patient and their reports
#* @delete /patients/<patient_id>
function(patient_id) {
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  db_delete_patient(con, patient_id)
  list(status = "ok", deleted = patient_id)
}

#* Download a patient's clinical PDF report (with SDTM + ADaM tabulations)
#* @serializer contentType list(type="application/pdf")
#* @get /patients/<patient_id>/report.pdf
function(patient_id, res) {
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  patient_row <- db_get_patient(con, patient_id)
  if (nrow(patient_row) == 0) {
    res$status <- 404
    return("No such patient.")
  }
  full_report <- db_get_report(con, patient_id)
  if (length(full_report) == 0) {
    res$status <- 404
    return("No report stored for this patient.")
  }
  patient <- list(patient_id = patient_id,
                   display_name = patient_row$display_name[1],
                   age = patient_row$age[1],
                   sex = patient_row$sex[1],
                   notes = patient_row$notes[1])
  tmp <- tempfile(fileext = ".pdf")
  generate_pdf_report(full_report, patient, output_path = tmp)
  readBin(tmp, "raw", n = file.info(tmp)$size)
}

#* Get a patient's SDTM + ADaM CDISC tabulations as JSON
#* @get /patients/<patient_id>/cdisc
function(patient_id, res) {
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  patient_row <- db_get_patient(con, patient_id)
  if (nrow(patient_row) == 0) {
    res$status <- 404
    return(list(error = "No such patient."))
  }
  full_report <- db_get_report(con, patient_id)
  cd <- build_cdisc(full_report, patient_id, patient_row$age[1], sex = patient_row$sex[1])
  list(meta = cd$meta, sdtm = cd$sdtm, adam = cd$adam)
}

#* Compute a new patient's percentile-for-age report and save it
#*
#* Request body (JSON):
#*   patient_id, display_name, age, sex, notes,
#*   stats: { "lh_vol": {"lh_bankssts_volume": 2873, ...}, "rh_vol": {...}, ... }
#*
#* `stats` keys must be one of: lh_vol, rh_vol, lh_thick, rh_thick,
#* lh_area, rh_area, seg_vol, hippo_vol, brainstem_vol - i.e. the same
#* keys returned by read_subject_stats_dir().
#* @post /patients
#* @serializer unboxedJSON
function(req, res) {
  body <- tryCatch(jsonlite::fromJSON(req$postBody, simplifyVector = FALSE),
                    error = function(e) NULL)
  if (is.null(body) || is.null(body$patient_id) || is.null(body$age) || is.null(body$stats)) {
    res$status <- 400
    return(list(error = "Body must include patient_id, age, and stats."))
  }

  subject_stats <- lapply(body$stats, function(region_list) {
    v <- vapply(region_list, function(x) as.numeric(x), numeric(1))
    names(v) <- names(region_list)
    v
  })

  full_report <- build_full_report(subject_stats, as.numeric(body$age), MODELS, NAMES_DIR)

  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  db_upsert_patient(con, body$patient_id,
                     display_name = body$display_name %||% body$patient_id,
                     age = as.numeric(body$age),
                     sex = body$sex %||% NA,
                     notes = body$notes %||% NA)
  db_save_report(con, body$patient_id, subject_stats, full_report)

  list(status = "ok", patient_id = body$patient_id, report = full_report)
}

`%||%` <- function(a, b) if (is.null(a)) b else a
