# -----------------------------------------------------------------------
# global.R - shared setup for the Shiny app (app.R) and the plumber web
# service (plumber.R). Source this first from both.
# -----------------------------------------------------------------------

# Required packages. If any are missing/unloadable we stop with a clear
# message naming them, rather than a truncated library() traceback (which
# is what you get when a package failed to compile in the Docker image).
.required_pkgs <- c("shiny", "DT", "ggplot2", "DBI", "RSQLite")
.missing_pkgs <- .required_pkgs[!vapply(.required_pkgs, requireNamespace,
                                        logical(1), quietly = TRUE)]
if (length(.missing_pkgs) > 0) {
  stop("Required R package(s) not installed or not loadable: ",
       paste(.missing_pkgs, collapse = ", "),
       ".\nInstall them with install.packages(c(",
       paste(sprintf('\"%s\"', .missing_pkgs), collapse = ", "), ")).",
       call. = FALSE)
}
suppressPackageStartupMessages({
  library(shiny)
  library(DT)
  library(ggplot2)
  library(DBI)
  library(RSQLite)
})

# Make sure relative paths (data/reference/..., data/patients.sqlite) work
# no matter where R was launched from, by rooting them at this file's
# directory.
app_root <- tryCatch(dirname(normalizePath(sys.frame(1)$ofile)),
                      error = function(e) getwd())
if (!is.null(app_root) && dir.exists(file.path(app_root, "R"))) {
  setwd(app_root)
}

for (f in list.files("R", pattern = "\\.R$", full.names = TRUE)) {
  source(f)
}

REFERENCE_DIR <- default_reference_dir()
NAMES_DIR     <- file.path("data", "reference", "region_names")
MODELS_PATH   <- default_models_path()
DB_PATH       <- default_db_path()

#' Load the fitted reference models, building them the first time if the
#' cached .rds doesn't exist yet.
load_or_build_models <- function(force_rebuild = FALSE, progress = message) {
  if (!force_rebuild && file.exists(MODELS_PATH)) {
    return(readRDS(MODELS_PATH))
  }
  build_reference_models(REFERENCE_DIR, MODELS_PATH, progress = progress)$models
}
