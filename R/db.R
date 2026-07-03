# -----------------------------------------------------------------------
# db.R
#
# Lightweight SQLite persistence layer (via DBI/RSQLite) for the patient
# database. This is new: the original pipeline just dropped a per-subject
# PDF/CSV in a folder. Here every processed patient - and every report
# generated for them - is written to a database the Shiny app and the
# plumber API both read from, so "generate new insights in one new
# patient alongside the db" means the new patient becomes queryable
# alongside every patient processed before them.
# -----------------------------------------------------------------------

#' Open (creating if needed) the patients SQLite database
db_connect <- function(path = default_db_path()) {
  dir.create(dirname(path), recursive = TRUE, showWarnings = FALSE)
  con <- DBI::dbConnect(RSQLite::SQLite(), path)
  DBI::dbExecute(con, "PRAGMA foreign_keys = ON;")
  db_init(con)
  con
}

default_db_path <- function() {
  Sys.getenv("NEUROIMAGING_DB_PATH", unset = file.path("data", "patients.sqlite"))
}

#' Create tables if they don't already exist
db_init <- function(con) {
  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS patients (
      patient_id   TEXT PRIMARY KEY,
      display_name TEXT,
      age          REAL NOT NULL,
      sex          TEXT,
      notes        TEXT,
      created_at   TEXT NOT NULL DEFAULT (datetime('now'))
    );")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS reports (
      report_id    INTEGER PRIMARY KEY AUTOINCREMENT,
      patient_id   TEXT NOT NULL REFERENCES patients(patient_id),
      region       TEXT NOT NULL,
      metric       TEXT NOT NULL,
      region_key   TEXT NOT NULL,
      label        TEXT,
      result       REAL,
      low_ref      REAL,
      high_ref     REAL,
      percentile   REAL,
      out_of_range INTEGER,
      n_reference  INTEGER,
      unit         TEXT,
      created_at   TEXT NOT NULL DEFAULT (datetime('now'))
    );")

  DBI::dbExecute(con, "
    CREATE TABLE IF NOT EXISTS raw_measurements (
      patient_id  TEXT NOT NULL REFERENCES patients(patient_id),
      region      TEXT NOT NULL,
      metric      TEXT NOT NULL,
      region_key  TEXT NOT NULL,
      value       REAL,
      created_at  TEXT NOT NULL DEFAULT (datetime('now'))
    );")
  invisible(con)
}

#' Insert or update a patient's demographic record
#'
#' Idempotent: re-saving an existing patient_id first clears that
#' patient's old reports and raw measurements so the foreign-key
#' constraint isn't violated and stale rows don't accumulate.
db_upsert_patient <- function(con, patient_id, display_name, age, sex = NA, notes = NA) {
  DBI::dbExecute(con, "DELETE FROM reports WHERE patient_id = ?;", params = list(patient_id))
  DBI::dbExecute(con, "DELETE FROM raw_measurements WHERE patient_id = ?;", params = list(patient_id))
  DBI::dbExecute(con, "DELETE FROM patients WHERE patient_id = ?;", params = list(patient_id))
  DBI::dbExecute(con, "
    INSERT INTO patients (patient_id, display_name, age, sex, notes)
    VALUES (?, ?, ?, ?, ?);",
    params = list(patient_id, display_name, age, sex, notes))
  invisible(TRUE)
}

#' Persist the full percentile report (list of data.frames from
#' build_full_report()) plus the raw measurements for one patient
db_save_report <- function(con, patient_id, subject_stats, full_report) {
  for (key in names(full_report)) {
    df <- full_report[[key]]
    if (nrow(df) == 0) next
    parts <- strsplit(key, "_")[[1]]
    region <- parts[1]; metric <- paste(parts[-1], collapse = "_")

    df$patient_id <- patient_id
    df$region <- region
    df$metric <- metric
    df$out_of_range <- as.integer(df$out_of_range)
    DBI::dbAppendTable(con, "reports", df[, c("patient_id", "region", "metric", "region_key",
                                               "label", "result", "low_ref", "high_ref",
                                               "percentile", "out_of_range", "n_reference", "unit")])

    raw <- subject_stats[[key]]
    raw_df <- data.frame(patient_id = patient_id, region = region, metric = metric,
                          region_key = names(raw), value = as.numeric(raw))
    DBI::dbAppendTable(con, "raw_measurements", raw_df)
  }
  invisible(TRUE)
}

#' List every patient currently in the database
db_list_patients <- function(con) {
  DBI::dbGetQuery(con, "
    SELECT p.patient_id, p.display_name, p.age, p.sex, p.notes, p.created_at,
           COUNT(DISTINCT r.report_id) AS n_report_rows,
           SUM(r.out_of_range) AS n_out_of_range
    FROM patients p
    LEFT JOIN reports r ON r.patient_id = p.patient_id
    GROUP BY p.patient_id
    ORDER BY p.created_at DESC;")
}

#' Fetch the most recent full report for one patient, as a named list of
#' data.frames keyed "region_metric" (same shape as build_full_report())
db_get_report <- function(con, patient_id) {
  df <- DBI::dbGetQuery(con, "SELECT * FROM reports WHERE patient_id = ?;",
                         params = list(patient_id))
  if (nrow(df) == 0) return(list())
  df$out_of_range <- as.logical(df$out_of_range)
  split_key <- paste(df$region, df$metric, sep = "_")
  split(df[, c("region_key", "label", "result", "low_ref", "high_ref",
               "percentile", "out_of_range", "n_reference", "unit")], split_key)
}

db_get_patient <- function(con, patient_id) {
  DBI::dbGetQuery(con, "SELECT * FROM patients WHERE patient_id = ?;",
                   params = list(patient_id))
}

db_delete_patient <- function(con, patient_id) {
  DBI::dbExecute(con, "DELETE FROM reports WHERE patient_id = ?;", params = list(patient_id))
  DBI::dbExecute(con, "DELETE FROM raw_measurements WHERE patient_id = ?;", params = list(patient_id))
  DBI::dbExecute(con, "DELETE FROM patients WHERE patient_id = ?;", params = list(patient_id))
  invisible(TRUE)
}
