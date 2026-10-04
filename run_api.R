# Launch the plumber web service.
#   Rscript run_api.R
#
# Configure with environment variables before launching, e.g.:
#   NEUROIMAGING_API_PORT=8000 Rscript run_api.R
port <- as.integer(Sys.getenv("NEUROIMAGING_API_PORT", unset = "8000"))

setwd(dirname(normalizePath(sub("--file=", "", grep("--file=", commandArgs(), value = TRUE)))))

pr <- plumber::plumb("plumber.R")
pr$run(host = "0.0.0.0", port = port)
