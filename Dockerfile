# ---------------------------------------------------------------------------
# Neuroimaging normative-reference app + web service
#
# One image runs both processes (managed by /entrypoint.sh):
#   * the plumber REST API   (default port 8000)
#   * the Shiny frontend      (default port 3838)
#
# Build:  docker build -t neuroimaging-shiny .
# Run:    docker run -p 3838:3838 -p 8000:8000 neuroimaging-shiny
# ---------------------------------------------------------------------------
FROM rocker/r-ver:4.3.3

# System libraries needed by the R packages (curl/ssl for httr, xml2 for
# some transitive deps, sqlite for RSQLite, fontconfig for PDF text).
RUN apt-get update && apt-get install -y --no-install-recommends \
        libcurl4-openssl-dev \
        libssl-dev \
        libxml2-dev \
        libsqlite3-dev \
        libfontconfig1-dev \
        libfreetype6-dev \
        libpng-dev \
    && rm -rf /var/lib/apt/lists/*

# R package dependencies. Pinned set kept small on purpose.
RUN R -q -e "install.packages(c( \
        'shiny','DT','ggplot2','DBI','RSQLite','plumber', \
        'httr','jsonlite','gridExtra' \
    ), repos='https://cloud.r-project.org')"

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
