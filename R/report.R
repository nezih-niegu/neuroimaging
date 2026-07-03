# -----------------------------------------------------------------------
# report.R
#
# R re-implementation of legacy/python_scripts/createPDFreport.py /
# createPDFreport_spanish.py: given one subject's FreeSurfer measurements,
# their age, and the fitted reference models, compute a percentile-for-age
# for every brain region and flag anything outside the normal reference
# range.
#
# Percentile formula (identical to the original python code): the 95%
# prediction interval [low, high] is assumed to run from the 2.5th to the
# 97.5th percentile; the patient's percentile is obtained by linearly
# interpolating their value between those two points.
# -----------------------------------------------------------------------

REGION_LABELS <- list(
  lh = "Left hemisphere", rh = "Right hemisphere", seg = "Subcortical",
  hippo = "Hippocampal subfields", brainstem = "Brainstem structures"
)

METRIC_UNITS <- list(vol = "mm3", area = "mm2", thick = "mm")
METRIC_ROUND <- list(vol = 0, area = 0, thick = 2)

#' Load a region-name lookup table (label -> friendly name) if available
load_region_names <- function(region, metric, names_dir) {
  fname <- switch(
    region,
    lh = , rh = switch(metric, vol = "hemisphere_names.csv",
                        thick = "hemisphere_names_thick.csv",
                        area = "hemisphere_names_area.csv"),
    seg = "subcortical_names.csv",
    hippo = "hippo_names.csv",
    brainstem = "brainstem_names.csv"
  )
  path <- file.path(names_dir, fname)
  if (!file.exists(path)) return(NULL)
  utils::read.csv(path, stringsAsFactors = FALSE)
}

#' Build a percentile-for-age report for one subject / region / metric
#'
#' @param subject_values named numeric vector, e.g. from
#'   read_subject_stats_dir()[["lh_vol"]]
#' @param age patient's age (numeric)
#' @param region one of "lh","rh","seg","hippo","brainstem"
#' @param metric one of "vol","area","thick"
#' @param models nested model list from build_reference_models() / readRDS()
#' @param names_dir directory containing the region-name lookup CSVs
#'   (defaults to the bundled data/reference/region_names)
#' @return data.frame with one row per brain region: region_key, label,
#'   result, low_ref, high_ref, percentile, out_of_range, unit
build_percentile_report <- function(subject_values, age, region, metric, models,
                                     names_dir = file.path("data", "reference", "region_names")) {
  region_metric <- paste(region, metric, sep = "_")
  grp <- age_group_for(age)
  unit <- METRIC_UNITS[[metric]]
  rd <- METRIC_ROUND[[metric]]

  cols <- names(subject_values)
  rows <- list()
  for (col in cols) {
    pi <- predict_interval(models, region_metric, grp, col, age)
    if (is.null(pi)) next

    value <- subject_values[[col]]
    p_slope <- (pi$upr - pi$lwr) / (97.5 - 2.5)
    p_intercept <- pi$lwr - p_slope * 2.5
    pct <- (value - p_intercept) / p_slope
    pct <- round(min(max(pct, 0), 100), 2)

    rows[[col]] <- data.frame(
      region_key = col,
      result = round(value, rd),
      low_ref = round(pi$lwr, rd),
      high_ref = round(pi$upr, rd),
      percentile = pct,
      out_of_range = value < pi$lwr || value > pi$upr,
      n_reference = pi$n,
      unit = unit,
      stringsAsFactors = FALSE
    )
  }
  if (length(rows) == 0) {
    return(data.frame(region_key = character(), label = character(),
                       result = numeric(), low_ref = numeric(), high_ref = numeric(),
                       percentile = numeric(), out_of_range = logical(),
                       n_reference = integer(), unit = character()))
  }
  report <- do.call(rbind, rows)
  rownames(report) <- NULL

  names_tbl <- load_region_names(region, metric, names_dir)
  report$label <- report$region_key
  if (!is.null(names_tbl) && "Label" %in% colnames(names_tbl)) {
    strip_key <- function(x) tolower(gsub("^lh_|^rh_|^left_|^right_|_volume$|_thickness$|_area$", "", x))
    m <- match(strip_key(report$region_key), tolower(names_tbl$Label))
    has_match <- !is.na(m)
    report$label[has_match] <- names_tbl$Name[m[has_match]]
  }
  report[, c("region_key", "label", "result", "low_ref", "high_ref",
             "percentile", "out_of_range", "n_reference", "unit")]
}

#' Build percentile reports for ALL region/metric combinations at once
#'
#' @param subject_stats output of read_subject_stats_dir(): named list
#'   keyed "lh_vol","rh_vol",... -> named numeric vector
#' @return named list of data.frames, same keys as subject_stats
build_full_report <- function(subject_stats, age, models,
                               names_dir = file.path("data", "reference", "region_names")) {
  out <- list()
  for (key in names(subject_stats)) {
    parts <- strsplit(key, "_")[[1]]
    region <- parts[1]; metric <- paste(parts[-1], collapse = "_")
    out[[key]] <- tryCatch(
      build_percentile_report(subject_stats[[key]], age, region, metric, models, names_dir),
      error = function(e) {
        warning(sprintf("Could not build report for %s: %s", key, conditionMessage(e)))
        data.frame()
      })
  }
  out
}

#' Scatter plot of the reference cohort with the patient highlighted
#'
#' Rebuilds the regression line + 95% prediction band for one brain
#' region column and overlays the patient's value at their age - a
#' direct visual analogue of legacy/batches/batches/batch_1/scatter_*.R.
#'
#' @param long_df reference long data.frame for this region/metric,
#'   filtered to the patient's age group (e.g. via build_reference_long())
#' @param column which brain-region column to plot
#' @param model the fitted lm object for that column
#' @param patient_age,patient_value patient's age and measured value
plot_reference_scatter <- function(long_df, column, model, patient_age, patient_value,
                                    unit = "", title = column) {
  sub <- long_df[long_df$column == column, ]
  age_seq <- seq(min(sub$age, patient_age, na.rm = TRUE),
                  max(sub$age, patient_age, na.rm = TRUE), length.out = 100)
  pred <- as.data.frame(stats::predict(model, newdata = data.frame(age = age_seq),
                                        interval = "prediction", level = 0.95))
  pred$age <- age_seq

  ggplot2::ggplot() +
    ggplot2::geom_ribbon(data = pred, ggplot2::aes(x = age, ymin = lwr, ymax = upr),
                          fill = "#a6cee3", alpha = 0.4) +
    ggplot2::geom_point(data = sub, ggplot2::aes(x = age, y = value),
                         color = "grey40", alpha = 0.6, size = 1.6) +
    ggplot2::geom_line(data = pred, ggplot2::aes(x = age, y = fit), color = "#1f78b4", linewidth = 1) +
    ggplot2::geom_point(ggplot2::aes(x = patient_age, y = patient_value),
                         color = "#e31a1c", size = 4, shape = 18) +
    ggplot2::labs(title = title, x = "Age (years)",
                  y = if (nzchar(unit)) paste0("Value (", unit, ")") else "Value") +
    ggplot2::theme_minimal(base_size = 13)
}
