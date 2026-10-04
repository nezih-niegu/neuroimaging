# -----------------------------------------------------------------------
# regression.R
#
# R re-implementation of the regression half of
# legacy/python_scripts/batches_joinsANDlms.py.
#
# For every brain region column (e.g. "lh_hippocampus_volume") within a
# region/metric/age-group, we fit:
#     value ~ age          (ordinary least squares)
# and keep the fitted lm object. A subject's 95% prediction interval at
# their exact age is then obtained with predict(model, interval =
# "prediction"), which is a direct, continuous-age analogue of the
# original python code's per-integer-age lookup dictionary.
#
# AGE_GROUPS mirrors the original two groups (documented in the legacy
# README): under 40, and 40 or older.
# -----------------------------------------------------------------------

AGE_GROUPS <- list(
  lessthan40years = list(min = -Inf, max = 40, label = "< 40 years"),
  `40ormoreyears`  = list(min = 40,  max = Inf, label = ">= 40 years")
)

age_group_for <- function(age) {
  for (nm in names(AGE_GROUPS)) {
    g <- AGE_GROUPS[[nm]]
    if (age >= g$min && age < g$max) return(nm)
  }
  stop("Could not assign an age group for age = ", age)
}

#' Fit one lm(value ~ age) model per brain-region column
#'
#' @param long_df output of build_reference_long()
#' @param min_n minimum number of subjects required to fit a model
#' @return named list: column name -> list(model = lm, n = int)
fit_models_for_group <- function(long_df, min_n = 8) {
  models <- list()
  for (col in unique(long_df$column)) {
    sub <- long_df[long_df$column == col, ]
    sub <- sub[stats::complete.cases(sub[, c("age", "value")]), ]
    if (nrow(sub) < min_n) next
    fit <- stats::lm(value ~ age, data = sub)
    models[[col]] <- list(model = fit, n = nrow(sub))
  }
  models
}

#' Build and save the full reference model set for every region/metric
#'
#' Scans the reference data tree, joins measurements to demographics,
#' splits into the two age groups, and fits one regression model per
#' brain-region column in each. The result is a single nested list saved
#' to `output_rds`:
#'   models[[region_metric]][[age_group]][[column]] = list(model, n)
#'
#' @param reference_dir directory containing the ICBM/PPMI/ADNI batches
#'   (defaults to the bundled data/reference/batches folder)
#' @param output_rds where to save the fitted model set
#' @param progress optional function(message) called to report progress
#'   (used by the Shiny app to show a progress bar)
build_reference_models <- function(reference_dir = default_reference_dir(),
                                    output_rds = default_models_path(),
                                    progress = message) {
  demo <- load_reference_demographics(reference_dir)
  progress(sprintf("Loaded demographics for %d control subjects.", nrow(demo)))

  region_metric_combos <- list(
    c("lh", "vol"), c("rh", "vol"), c("lh", "thick"), c("rh", "thick"),
    c("lh", "area"), c("rh", "area"), c("seg", "vol"),
    c("hippo", "vol"), c("brainstem", "vol")
  )

  all_models <- list()
  fit_log <- list()

  for (combo in region_metric_combos) {
    region <- combo[1]; metric <- combo[2]
    key <- paste(region, metric, sep = "_")
    progress(sprintf("Building reference dataset for %s ...", key))
    long_df <- build_reference_long(reference_dir, region, metric, demo)
    if (nrow(long_df) == 0) {
      progress(sprintf("  -> no data found for %s, skipping.", key))
      next
    }
    long_df$age_group <- vapply(long_df$age, age_group_for, character(1))

    group_models <- list()
    for (grp in names(AGE_GROUPS)) {
      grp_df <- long_df[long_df$age_group == grp, ]
      if (nrow(grp_df) == 0) next
      m <- fit_models_for_group(grp_df)
      group_models[[grp]] <- m
      fit_log[[length(fit_log) + 1]] <- data.frame(
        region_metric = key, age_group = grp,
        n_subjects = length(unique(grp_df$subject_id)),
        n_columns_fit = length(m)
      )
    }
    all_models[[key]] <- group_models
    progress(sprintf("  -> fit models for %s.", key))
  }

  dir.create(dirname(output_rds), recursive = TRUE, showWarnings = FALSE)
  saveRDS(all_models, output_rds)
  log_df <- if (length(fit_log)) do.call(rbind, fit_log) else data.frame()
  attr(all_models, "fit_log") <- log_df
  progress("Reference model set saved.")
  invisible(list(models = all_models, fit_log = log_df))
}

#' Predict a subject's 95% prediction interval for one region column
#'
#' @param models the nested list produced by build_reference_models()
#' @param region_metric e.g. "lh_vol"
#' @param age_group e.g. "40ormoreyears"
#' @param column brain region/measure name
#' @param age patient's exact age
#' @return list(fit, lwr, upr, n) or NULL if no model is available
predict_interval <- function(models, region_metric, age_group, column, age) {
  grp_models <- models[[region_metric]][[age_group]]
  if (is.null(grp_models) || is.null(grp_models[[column]])) return(NULL)
  entry <- grp_models[[column]]
  pred <- stats::predict(entry$model, newdata = data.frame(age = age),
                          interval = "prediction", level = 0.95)
  list(fit = unname(pred[1, "fit"]), lwr = unname(pred[1, "lwr"]),
       upr = unname(pred[1, "upr"]), n = entry$n)
}

default_reference_dir <- function() {
  env_dir <- Sys.getenv("NEUROIMAGING_REFERENCE_DIR", unset = NA)
  candidates <- c(env_dir, file.path("data", "reference", "batches"))
  candidates <- candidates[!is.na(candidates)]
  hit <- candidates[dir.exists(candidates)]
  if (length(hit) == 0) stop("Could not locate the reference batches directory. ",
                              "Set the NEUROIMAGING_REFERENCE_DIR environment variable, ",
                              "or run the app from the project root (app.R's directory).")
  hit[1]
}

default_models_path <- function() {
  Sys.getenv("NEUROIMAGING_MODELS_PATH", unset = file.path("data", "reference_models.rds"))
}
