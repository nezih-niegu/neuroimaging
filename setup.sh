#!/usr/bin/env bash
# ===========================================================================
# setup.sh - set up the WHOLE project on Ubuntu 24.04 with one command:
#
#     sudo ./setup.sh --license ~/license.txt
#
# Installs and configures, in order:
#   1. the app: R + all R packages, dcm2niix, DICOM tools        (Ubuntu archive)
#   2. FreeSurfer 8.2.0 (official freesurfer_ubuntu24 .deb) + your license
#   3. the MATLAB runtime R2019b (hippocampal subfields / brainstem)
#   4. MNE-Python + PyVista + Xvfb (brain visualisation, works headless)
#   5. project config: /etc/neuroimaging/neuroimaging.env, `neuroimaging` command,
#      data folders owned by you, reference models pre-built
#   6. optional systemd service for the app + API (--service)
#   7. a self-test of the whole pipeline, then an environment report
#
# Settings can also come from a setup.conf file (see setup.conf.example);
# options on the command line win. Safe to re-run: finished parts are skipped
# or refreshed.
#
# Options:
#   --license FILE      FreeSurfer license.txt
#   --config FILE       settings file (default: ./setup.conf if present)
#   --fs-deb FILE       use a downloaded freesurfer_ubuntu24-*.deb (no download)
#   --fs-version VER    FreeSurfer version (default 8.2.0)
#   --no-freesurfer     skip FreeSurfer (app + MNE only; e.g. a viewing-only server)
#   --no-mcr            skip the MATLAB runtime
#   --no-mne            skip MNE-Python
#   --service           install + start the systemd service (app :3838, API :8000)
#   --user NAME         account that owns data / runs the service (default: sudo user)
#   --skip-tests        don't run the self-test
#   -h, --help
# ===========================================================================
set -Eeuo pipefail
PROJECT_ROOT="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
LOG="/var/log/neuroimaging-setup.log"

say()  { printf '\n\033[1m==> %s\033[0m\n' "$*"; }
warn() { printf '\033[33mWARNING:\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
yes_()  { [[ "${1,,}" =~ ^(1|y|yes|true|on)$ ]]; }

# ---- defaults, then config file, then command line ------------------------
INSTALL_FREESURFER=yes FS_VERSION=8.2.0 FS_DEB="" FS_LICENSE_FILE="" INSTALL_MCR=yes
INSTALL_MNE=yes MNE_VENV=/opt/neuroimaging/venv SUBJECTS_DIR_CFG="" PROCESSED_DIR=""
INSTALL_SERVICE=no SERVICE_USER="" API_PORT=8000 APP_PORT=3838 RUN_TESTS=yes REFERENCE_DIR=""
CONFIG=""

args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  [[ "${args[$i]}" == --config ]] && CONFIG="${args[$((i + 1))]:-}"
done
[[ -z "$CONFIG" && -f "$PROJECT_ROOT/setup.conf" ]] && CONFIG="$PROJECT_ROOT/setup.conf"
if [[ -n "$CONFIG" ]]; then
  [[ -f "$CONFIG" ]] || die "config file not found: $CONFIG"
  # parse KEY=value lines (no shell evaluation of the file)
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"; line="${line#"${line%%[![:space:]]*}"}"; line="${line%"${line##*[![:space:]]}"}"
    [[ -z "$line" ]] && continue
    [[ "$line" =~ ^([A-Z_]+)=(.*)$ ]] || { warn "ignoring config line: $line"; continue; }
    key="${BASH_REMATCH[1]}" val="${BASH_REMATCH[2]}"
    val="${val%\"}"; val="${val#\"}"; val="${val%\'}"; val="${val#\'}"
    case "$key" in
      INSTALL_FREESURFER|FS_VERSION|FS_DEB|FS_LICENSE_FILE|INSTALL_MCR|INSTALL_MNE|MNE_VENV|\
      PROCESSED_DIR|INSTALL_SERVICE|SERVICE_USER|API_PORT|APP_PORT|RUN_TESTS|REFERENCE_DIR) printf -v "$key" '%s' "$val" ;;
      SUBJECTS_DIR) SUBJECTS_DIR_CFG="$val" ;;
      *) warn "unknown setting $key in $CONFIG" ;;
    esac
  done < "$CONFIG"
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --license)       FS_LICENSE_FILE="$2"; shift 2 ;;
    --config)        shift 2 ;;
    --fs-deb)        FS_DEB="$2"; shift 2 ;;
    --fs-version)    FS_VERSION="$2"; shift 2 ;;
    --no-freesurfer) INSTALL_FREESURFER=no; shift ;;
    --no-mcr)        INSTALL_MCR=no; shift ;;
    --no-mne)        INSTALL_MNE=no; shift ;;
    --service)       INSTALL_SERVICE=yes; shift ;;
    --user)          SERVICE_USER="$2"; shift 2 ;;
    --skip-tests)    RUN_TESTS=no; shift ;;
    -h|--help)       sed -n '2,37p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done

# ---- preflight ---------------------------------------------------------------
[[ $EUID -eq 0 ]] || die "run with sudo:  sudo ./setup.sh ${args[*]-}"
. /etc/os-release
[[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]] || die "setup.sh targets Ubuntu 24.04 (this is ${PRETTY_NAME:-unknown})"
if yes_ "$INSTALL_FREESURFER" && [[ "$(uname -m)" != x86_64 ]]; then
  warn "FreeSurfer's Ubuntu package is x86_64-only; skipping FreeSurfer on $(uname -m)"
  INSTALL_FREESURFER=no
fi
SERVICE_USER="${SERVICE_USER:-${SUDO_USER:-root}}"
id "$SERVICE_USER" >/dev/null 2>&1 || die "user '$SERVICE_USER' does not exist"
USER_HOME="$(getent passwd "$SERVICE_USER" | cut -d: -f6)"
[[ "$API_PORT" =~ ^[0-9]+$ && "$APP_PORT" =~ ^[0-9]+$ ]] || die "API_PORT/APP_PORT must be numbers"

# find the license if it wasn't given
if yes_ "$INSTALL_FREESURFER" && [[ -z "$FS_LICENSE_FILE" ]]; then
  for f in "$PROJECT_ROOT/freesurfer_license/license.txt" "$USER_HOME/license.txt" \
           "$USER_HOME/freesurfer_license.txt" /usr/local/freesurfer/license.txt; do
    [[ -s "$f" ]] && { FS_LICENSE_FILE="$f"; break; }
  done
fi
[[ -z "$FS_LICENSE_FILE" || -s "$FS_LICENSE_FILE" ]] || die "license file not found or empty: $FS_LICENSE_FILE"

# disk space: the FreeSurfer package is several GB to download and ~2-3x that installed
if yes_ "$INSTALL_FREESURFER" && [[ -z "$FS_DEB" ]]; then
  free_gb=$(( $(df --output=avail -k /usr/local | tail -1) / 1024 / 1024 ))
  (( free_gb >= 25 )) || warn "only ${free_gb} GB free under /usr/local; FreeSurfer needs roughly 25 GB during install"
fi

exec > >(tee -a "$LOG") 2>&1
say "Neuroimaging setup ($(date '+%F %T')) - log: $LOG"
echo "Project:     $PROJECT_ROOT"
echo "User:        $SERVICE_USER"
echo "FreeSurfer:  $(yes_ "$INSTALL_FREESURFER" && echo "$FS_VERSION${FS_DEB:+ from $FS_DEB}" || echo no)"
echo "License:     ${FS_LICENSE_FILE:-(none yet)}"
echo "MATLAB rt:   $INSTALL_MCR    MNE: $INSTALL_MNE ($MNE_VENV)    service: $INSTALL_SERVICE"

# ---- 1-4. software -----------------------------------------------------------
inst=("$PROJECT_ROOT/install/install_ubuntu24.sh")
if yes_ "$INSTALL_FREESURFER"; then
  if [[ -f "/usr/local/freesurfer/$FS_VERSION/SetUpFreeSurfer.sh" ]]; then
    echo "FreeSurfer $FS_VERSION already installed - keeping it"
    [[ -n "$FS_LICENSE_FILE" ]] && install -m 0644 "$FS_LICENSE_FILE" /usr/local/freesurfer/license.txt
    if yes_ "$INSTALL_MCR" && ! ls -d /usr/local/freesurfer/"$FS_VERSION"/MCRv* >/dev/null 2>&1; then
      (export FREESURFER_HOME="/usr/local/freesurfer/$FS_VERSION"; set +u
       . "$FREESURFER_HOME/SetUpFreeSurfer.sh" >/dev/null 2>&1; fs_install_mcr R2019b)
    fi
  else
    inst+=(--freesurfer --fs-version "$FS_VERSION")
    [[ -n "$FS_DEB" ]] && inst+=(--fs-deb "$FS_DEB")
    [[ -n "$FS_LICENSE_FILE" ]] && inst+=(--license "$FS_LICENSE_FILE")
    yes_ "$INSTALL_MCR" && inst+=(--with-mcr)
  fi
fi
yes_ "$INSTALL_MNE" && inst+=(--mne --mne-venv "$MNE_VENV")
say "Installing software (app$(yes_ "$INSTALL_FREESURFER" && echo ", FreeSurfer")$(yes_ "$INSTALL_MNE" && echo ", MNE-Python"))"
"${inst[@]}"

# ---- 5. project configuration -------------------------------------------------
say "Configuring the project"
SD="${SUBJECTS_DIR_CFG:-$PROJECT_ROOT/data/freesurfer_subjects}"
PD="${PROCESSED_DIR:-$PROJECT_ROOT/data/processed}"
mkdir -p /etc/neuroimaging "$SD" "$PD" "$PROJECT_ROOT/data/incoming" "$PROJECT_ROOT/data/jobs"
FS_HOME_LINE=""
if [[ -f "/usr/local/freesurfer/$FS_VERSION/SetUpFreeSurfer.sh" ]]; then
  FS_HOME_LINE="FREESURFER_HOME=/usr/local/freesurfer/$FS_VERSION"
fi
cat > /etc/neuroimaging/neuroimaging.env <<EOF
# written by setup.sh $(date '+%F %T') - read by the service and by login shells
NEUROIMAGING_HOME=$PROJECT_ROOT
NEUROIMAGING_SUBJECTS_DIR=$SD
NEUROIMAGING_PROCESSED_DIR=$PD
NEUROIMAGING_INCOMING_DIR=$PROJECT_ROOT/data/incoming
NEUROIMAGING_JOBS_DIR=$PROJECT_ROOT/data/jobs
NEUROIMAGING_DB_PATH=$PROJECT_ROOT/data/patients.sqlite
NEUROIMAGING_REFERENCE_DIR=${REFERENCE_DIR:-$PROJECT_ROOT/data/reference/batches}
NEUROIMAGING_MNE_PYTHON=$MNE_VENV/bin/python
NEUROIMAGING_API_PORT=$API_PORT
NEUROIMAGING_APP_PORT=$APP_PORT
NEUROIMAGING_API_URL=http://127.0.0.1:$API_PORT
$FS_HOME_LINE
$( [[ -s /usr/local/freesurfer/license.txt ]] && echo "FS_LICENSE=/usr/local/freesurfer/license.txt" )
EOF
cat > /etc/profile.d/neuroimaging.sh <<'EOF'
# Neuroimaging project environment (written by setup.sh)
if [ -r /etc/neuroimaging/neuroimaging.env ]; then
  set -a; . /etc/neuroimaging/neuroimaging.env; set +a
fi
EOF
ln -sf "$PROJECT_ROOT/bin/neuroimaging" /usr/local/bin/neuroimaging
chmod +x "$PROJECT_ROOT"/setup.sh "$PROJECT_ROOT"/bin/* "$PROJECT_ROOT"/pipeline/*.sh \
         "$PROJECT_ROOT"/pipeline/lib/*.py "$PROJECT_ROOT"/install/*.sh "$PROJECT_ROOT"/tests/*.sh \
         "$PROJECT_ROOT"/entrypoint.sh
chown -R "$SERVICE_USER": "$PROJECT_ROOT/data" "$SD" "$PD"
[[ -n "$REFERENCE_DIR" ]] && { mkdir -p "$REFERENCE_DIR"; chown -R "$SERVICE_USER": "$REFERENCE_DIR"; }
echo "Wrote /etc/neuroimaging/neuroimaging.env and /etc/profile.d/neuroimaging.sh; 'neuroimaging' is on PATH"

# run a command as the project user with the project environment loaded
as_user() (
  set -a; . /etc/neuroimaging/neuroimaging.env; set +a
  export HOME="$USER_HOME"
  if [[ "$SERVICE_USER" == root ]]; then exec "$@"; else exec runuser -u "$SERVICE_USER" -- "$@"; fi
)

say "Pre-building the reference models"
(cd "$PROJECT_ROOT" && as_user Rscript -e \
  "suppressMessages(source('global.R')); invisible(load_or_build_models(force_rebuild = TRUE)); cat('models ok\n')")

# ---- 6. service ----------------------------------------------------------------
if yes_ "$INSTALL_SERVICE"; then
  say "Installing systemd service 'neuroimaging'"
  cat > /etc/systemd/system/neuroimaging.service <<EOF
[Unit]
Description=Neuroimaging normative reference (Shiny app :$APP_PORT + REST API :$API_PORT)
After=network.target

[Service]
User=$SERVICE_USER
WorkingDirectory=$PROJECT_ROOT
EnvironmentFile=/etc/neuroimaging/neuroimaging.env
ExecStart=$PROJECT_ROOT/entrypoint.sh
Restart=on-failure
RestartSec=5
# recon-all runs launched from the app outlive a service restart
KillMode=process

[Install]
WantedBy=multi-user.target
EOF
  if [[ -d /run/systemd/system ]]; then
    systemctl daemon-reload
    systemctl enable --now neuroimaging.service
    sleep 3; systemctl --no-pager --lines=0 status neuroimaging.service || true
  else
    warn "systemd is not running here; the unit is installed but not started"
  fi
fi

# ---- 7. self-test + report -----------------------------------------------------------
if yes_ "$RUN_TESTS"; then
  say "Self-test (stub FreeSurfer + synthetic DICOMs; checks pipeline, report, MNE figures)"
  (cd "$PROJECT_ROOT" && as_user tests/test_pipeline.sh) || warn "self-test failed - see output above"
fi

say "Reference cohorts (which ICBM / PPMI / ADNI subjects the models use)"
(cd "$PROJECT_ROOT" && as_user Rscript bin/reference_report.R) || true

say "Environment"
as_user "$PROJECT_ROOT/pipeline/check_environment.sh" || true

cat <<EOF

Setup finished.
  Open a new terminal (or run: source /etc/profile.d/neuroimaging.sh), then:
    neuroimaging check
    neuroimaging process --subject sub-001 --dicom /path/to/dicom --report
    neuroimaging serve          # app http://localhost:$APP_PORT  API http://localhost:$API_PORT/__docs__/
EOF
[[ -z "$FS_LICENSE_FILE" ]] && yes_ "$INSTALL_FREESURFER" && \
  echo "  * FreeSurfer has no license yet: re-run  sudo ./setup.sh --license /path/to/license.txt"
exit 0
