# Launch the Shiny frontend.
#   Rscript run_app.R
#
# Make sure the plumber API is running first (see run_api.R) - by default
# the app expects it at http://127.0.0.1:8000, configurable with:
#   NEUROIMAGING_API_URL=http://127.0.0.1:8000 Rscript run_app.R
setwd(dirname(normalizePath(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)))))
shiny::runApp(".", host = "0.0.0.0", port = as.integer(Sys.getenv("NEUROIMAGING_APP_PORT", "3838")))
