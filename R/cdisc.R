# -----------------------------------------------------------------------
# cdisc.R
#
# Transform the internal percentile-for-age report into CDISC-standard
# tabulations for the generated PDF:
#
#   * SDTM  (Study Data Tabulation Model) - the observed/collected data,
#     organised as a Findings-class domain. Quantitative neuroimaging
#     region measurements have no dedicated base-SDTM domain, so we use a
#     custom Findings domain with the two-letter code "ZB" (sponsor-
#     defined "Brain Volumetry/Morphometry"), following the SDTM Findings
#     general-observation-class variable conventions.
#
#   * ADaM  (Analysis Data Model) - the analysis-ready data in Basic Data
#     Structure (BDS) form, one row per parameter. This is where the
#     reference interval and the reference-range indicator live
#     (ANRLO/ANRHI/ANRIND), which map naturally onto our low_ref /
#     high_ref / out-of-range logic, plus the age-group grouping variable
#     AGEGR1 that the regression models already use.
#
# These are deliberately faithful to the CDISC variable names so the PDF
# output can drop straight into a clinical-study documentation package.
# -----------------------------------------------------------------------

#' Flatten the per-region-metric report list into one long data.frame
#'
#' @param full_report named list keyed "region_metric" -> data.frame,
#'   from build_full_report()
#' @return one data.frame with region/metric columns added
flatten_report <- function(full_report) {
  parts_list <- list()
  for (key in names(full_report)) {
    df <- full_report[[key]]
    if (is.null(df) || nrow(df) == 0) next
    kp <- strsplit(key, "_")[[1]]
    df$region <- kp[1]
    df$metric <- paste(kp[-1], collapse = "_")
    parts_list[[key]] <- df
  }
  if (length(parts_list) == 0) return(data.frame())
  do.call(rbind, parts_list)
}

# FreeSurfer metric -> CDISC test-name fragments / units
.metric_meta <- list(
  vol   = list(name = "Volume",    unit = "mm3"),
  area  = list(name = "Area",      unit = "mm2"),
  thick = list(name = "Thickness", unit = "mm")
)
.region_meta <- list(
  lh = "Left Hemisphere", rh = "Right Hemisphere", seg = "Subcortical",
  hippo = "Hippocampal Subfield", brainstem = "Brainstem"
)

#' Build a short (<= 8 char) SDTM --TESTCD from a region key + metric
#'
#' SDTM test codes must be <= 8 chars, start with a letter, contain only
#' A-Z/0-9/_. We derive a stable, collision-resistant code from a hash of
#' the full region key so that every distinct region/metric gets a unique
#' code while --TEST carries the human-readable description.
make_testcd <- function(region_key, metric) {
  base <- toupper(gsub("[^A-Za-z0-9]", "", paste0(substr(metric, 1, 1), region_key)))
  if (nchar(base) <= 8) return(base)
  h <- substr(toupper(digest_like(paste(region_key, metric))), 1, 5)
  paste0(substr(base, 1, 3), h)
}

# Tiny dependency-free hash so we don't require the digest package
digest_like <- function(x) {
  ints <- utf8ToInt(x)
  val <- 5381
  for (i in ints) val <- (val * 33 + i) %% 2147483647
  format(as.hexmode(val))
}

human_test_name <- function(label, region, metric) {
  mm <- .metric_meta[[metric]]$name %||% metric
  sprintf("%s %s", label, mm)
}

#' Convert the flattened report to an SDTM Findings-class domain (ZB)
#'
#' @param report_flat data.frame from flatten_report()
#' @param usubjid unique subject identifier (STUDYID.SUBJID)
#' @param studyid study identifier
#' @param visitnum,visit visit metadata (single imaging visit by default)
#' @return data.frame with SDTM Findings variables
to_sdtm <- function(report_flat, usubjid, studyid = "NEUROIMG",
                    visitnum = 1, visit = "IMAGING") {
  if (nrow(report_flat) == 0) return(data.frame())
  n <- nrow(report_flat)
  data.frame(
    STUDYID  = studyid,
    DOMAIN   = "ZB",
    USUBJID  = usubjid,
    ZBSEQ    = seq_len(n),
    ZBTESTCD = mapply(make_testcd, report_flat$region_key, report_flat$metric),
    ZBTEST   = mapply(human_test_name, report_flat$label, report_flat$region, report_flat$metric),
    ZBCAT    = vapply(report_flat$region, function(r) .region_meta[[r]] %||% r, character(1)),
    ZBORRES  = as.character(report_flat$result),
    ZBORRESU = report_flat$unit,
    ZBSTRESC = as.character(report_flat$result),
    ZBSTRESN = as.numeric(report_flat$result),
    ZBSTRESU = report_flat$unit,
    ZBMETHOD = "FREESURFER RECON-ALL",
    VISITNUM = visitnum,
    VISIT    = visit,
    stringsAsFactors = FALSE, row.names = NULL
  )
}

#' Convert the flattened report to an ADaM BDS analysis dataset
#'
#' The reference interval populates ANRLO/ANRHI, and ANRIND is the
#' reference-range indicator (LOW / NORMAL / HIGH). PCTLREF is a custom
#' analysis variable carrying the percentile-for-age.
#'
#' @param report_flat data.frame from flatten_report()
#' @param usubjid,studyid identifiers
#' @param age,age_group patient age and its analysis grouping
#' @return data.frame with ADaM BDS variables
to_adam <- function(report_flat, usubjid, age, age_group,
                    studyid = "NEUROIMG", sex = NA) {
  if (nrow(report_flat) == 0) return(data.frame())
  n <- nrow(report_flat)

  anrind <- ifelse(report_flat$result < report_flat$low_ref, "LOW",
             ifelse(report_flat$result > report_flat$high_ref, "HIGH", "NORMAL"))
  agegr1 <- AGE_GROUPS[[age_group]]$label %||% age_group

  data.frame(
    STUDYID  = studyid,
    USUBJID  = usubjid,
    PARAMCD  = mapply(make_testcd, report_flat$region_key, report_flat$metric),
    PARAM    = sprintf("%s (%s)",
                        mapply(human_test_name, report_flat$label, report_flat$region, report_flat$metric),
                        report_flat$unit),
    PARAMTYP = "DERIVED",
    AVAL     = as.numeric(report_flat$result),
    AVALU    = report_flat$unit,
    ANRLO    = as.numeric(report_flat$low_ref),
    ANRHI    = as.numeric(report_flat$high_ref),
    ANRIND   = anrind,
    PCTLREF  = as.numeric(report_flat$percentile),
    AGE      = age,
    AGEU     = "YEARS",
    AGEGR1   = agegr1,
    SEX      = sex,
    DTYPE    = NA_character_,
    NREF     = as.integer(report_flat$n_reference),
    stringsAsFactors = FALSE, row.names = NULL
  )
}

#' Build both SDTM and ADaM tables plus a small metadata list
#'
#' @return list(sdtm, adam, meta)
build_cdisc <- function(full_report, patient_id, age, sex = NA,
                        studyid = "NEUROIMG") {
  flat <- flatten_report(full_report)
  usubjid <- paste(studyid, patient_id, sep = "-")
  ag <- tryCatch(age_group_for(age), error = function(e) NA_character_)
  list(
    sdtm = to_sdtm(flat, usubjid, studyid),
    adam = to_adam(flat, usubjid, age, ag, studyid, sex),
    meta = list(studyid = studyid, usubjid = usubjid, patient_id = patient_id,
                age = age, age_group = ag, n_params = nrow(flat))
  )
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a
