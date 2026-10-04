# ---------------------------------------------------------------------------
# Neuroimaging normative reference: Shiny app + REST API + FreeSurfer pipeline
#
# Base: Ubuntu 24.04. R and all R packages come from Ubuntu's own archive
# (r-cran-*), MNE-Python goes into /opt/neuroimaging/venv - all installed by the
# same script setup.sh uses on workstations (install/install_ubuntu24.sh), so
# the container and a workstation are configured identically.
#
#   App only (multi-arch: amd64 + arm64/Apple Silicon):
#     docker build -t neuroimaging .
#
#   App + FreeSurfer 8.2.0 (amd64 only, adds several GB):
#     docker build --build-arg WITH_FREESURFER=1 -t neuroimaging-fs .
#     # offline / faster: put freesurfer_ubuntu24-8.2.0_amd64.deb in install/
#     # and add --build-arg FS_DEB=install/freesurfer_ubuntu24-8.2.0_amd64.deb
#
# The FreeSurfer license is NOT baked in: mount it at runtime, e.g.
#     -v /path/to/folder_with_license:/fs_license:ro   (folder containing license.txt)
# ---------------------------------------------------------------------------
FROM ubuntu:24.04

ARG WITH_FREESURFER=0
ARG FS_VERSION=8.2.0
ARG FS_DEB=""
ARG WITH_MCR=1
# MNE-Python visualisation (surfaces on T1, 3D parcellation; renders headless via Xvfb)
ARG WITH_MNE=1

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    TZ=Etc/UTC

WORKDIR /app

# 1. app dependencies (and, optionally, FreeSurfer) via the project installer
COPY install/ /app/install/
COPY pipeline/ /app/pipeline/
RUN set -eux; \
    if [ "$WITH_MNE" = "1" ]; then install/install_ubuntu24.sh --mne; else install/install_ubuntu24.sh; fi; \
    if [ "$WITH_FREESURFER" = "1" ]; then \
        fs_args="--freesurfer --fs-version $FS_VERSION"; \
        [ -n "$FS_DEB" ] && fs_args="$fs_args --fs-deb /app/$FS_DEB"; \
        [ "$WITH_MCR" = "1" ] && fs_args="$fs_args --with-mcr"; \
        install/install_ubuntu24.sh --skip-app $fs_args; \
        rm -f /tmp/freesurfer_ubuntu24-*.deb /app/install/*.deb; \
    fi; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# 2. application code + bundled reference data
COPY R/ /app/R/
COPY bin/ /app/bin/
COPY global.R plumber.R app.R run_api.R run_app.R entrypoint.sh setup.sh setup.conf.example /app/
COPY data/reference/ /app/data/reference/
COPY examples/ /app/examples/
COPY tests/ /app/tests/
RUN chmod +x /app/entrypoint.sh /app/bin/* /app/pipeline/*.sh /app/pipeline/lib/*.py \
 && ln -s /app/bin/neuroimaging /usr/local/bin/neuroimaging

# 3. pre-fit the reference models so the first request is fast
RUN Rscript -e "source('global.R'); invisible(load_or_build_models(force_rebuild = TRUE))"

# FreeSurfer environment (harmless when FreeSurfer isn't installed: the
# pipeline auto-detects /usr/local/freesurfer/<version>)
ENV FS_LICENSE=/fs_license/license.txt \
    NEUROIMAGING_API_PORT=8000 \
    NEUROIMAGING_APP_PORT=3838 \
    NEUROIMAGING_API_URL=http://127.0.0.1:8000 \
    NEUROIMAGING_SUBJECTS_DIR=/app/data/freesurfer_subjects \
    NEUROIMAGING_INCOMING_DIR=/app/data/incoming \
    NEUROIMAGING_PROCESSED_DIR=/app/data/processed \
    NEUROIMAGING_MNE_PYTHON=/opt/neuroimaging/venv/bin/python

# patients DB, FreeSurfer subjects, uploads, pipeline outputs and job logs
VOLUME ["/app/data"]
EXPOSE 8000 3838
ENTRYPOINT ["/app/entrypoint.sh"]
