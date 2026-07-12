# ---------------------------------------------------------------------------
# Neuroimaging normative-reference app + web service
#
# One image runs both processes (managed by /entrypoint.sh):
#   * the plumber REST API   (default port 8000)
#   * the Shiny frontend      (default port 3838)
#
# Build:  docker build -t neuroimaging-shiny .
# Run:    docker run -p 3838:3838 -p 8000:8000 neuroimaging-shiny
#
# Base image: rocker/r-ver publishes BOTH linux/amd64 and linux/arm64
# (Apple Silicon) images, so this builds natively on an M-series Mac with
# no emulation. We install Shiny ourselves along with the other packages.
# ---------------------------------------------------------------------------
FROM rocker/r-ver:4.3.3

# System libraries the R packages need to build and run:
#   libcurl/ssl            -> httr, and package downloads
#   libsodium              -> sodium (a plumber dependency)
#   libxml2                -> transitive deps
#   libsqlite3             -> RSQLite
#   fontconfig/freetype/png-> ggplot2 + gridExtra PDF text rendering
#   libcairo2/libxt        -> shiny / httpuv graphics stack
#   zlib                   -> several packages' compression support
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libssl-dev \
        libsodium-dev \
        libxml2-dev \
        libsqlite3-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libpng-dev \
        libcairo2-dev \
        libxt-dev \
        zlib1g-dev \
    && rm -rf /var/lib/apt/lists/*

# All R package dependencies (including shiny). rocker/r-ver points
# install.packages() at the Posit Public Package Manager, which serves
# precompiled binaries for the image's platform where available and falls
# back to source otherwise.
#
# CRITICAL: verify every package can actually be loaded and stop the build
# with a non-zero exit if any failed, instead of letting a broken package
# surface later as a cryptic library() error during the model prebuild.
RUN R -q -e "\
    pkgs <- c('shiny','DT','ggplot2','DBI','RSQLite','plumber','httr','jsonlite','gridExtra'); \
    install.packages(pkgs); \
    ok <- sapply(pkgs, requireNamespace, quietly = TRUE); \
    if (any(!ok)) { \
        message('FAILED to install: ', paste(names(ok)[!ok], collapse=', ')); \
        quit(status = 1); \
    } else message('All R packages installed and loadable.') \
    "

WORKDIR /app

# App code + bundled reference data
COPY R/            /app/R/
COPY global.R plumber.R app.R run_api.R run_app.R /app/
COPY data/reference/ /app/data/reference/
COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# Pre-build the reference regression models at image-build time so the
# first request is fast. Writes data/reference_models.rds into the image.
RUN R -q -e "source('global.R'); load_or_build_models(force_rebuild=TRUE)"

# The SQLite patient DB and the models live under /app/data; mount a
# volume here to persist patients across container restarts.
VOLUME ["/app/data"]

ENV NEUROIMAGING_API_PORT=8000 \
    NEUROIMAGING_APP_PORT=3838 \
    NEUROIMAGING_API_URL=http://127.0.0.1:8000

EXPOSE 8000 3838

ENTRYPOINT ["/entrypoint.sh"]
