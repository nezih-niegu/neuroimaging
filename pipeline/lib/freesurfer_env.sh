#!/usr/bin/env bash
# ---------------------------------------------------------------------------
# freesurfer_env.sh - locate and validate a FreeSurfer 7.x / 8.x install.
# Sourced by neuroimaging-pipeline.sh and check_environment.sh.
#
# Ubuntu 24.04: install FreeSurfer 8.x from the official
# freesurfer_ubuntu24-<ver>_amd64.deb (see install/install_ubuntu24.sh); it
# lands in /usr/local/freesurfer/<ver>. FreeSurfer 7.4.x has no Ubuntu 24
# package and is not supported on 24.04 by the FreeSurfer team.
# ---------------------------------------------------------------------------

log()  { printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }
warn() { printf '[%s] WARNING: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; }
die()  { printf '[%s] ERROR: %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >&2; exit 1; }

# Find FREESURFER_HOME if it isn't set: newest /usr/local/freesurfer/<ver>,
# then the classic /usr/local/freesurfer layout, then /opt/freesurfer.
fs_locate_home() {
  if [[ -n "${FREESURFER_HOME:-}" && -f "$FREESURFER_HOME/SetUpFreeSurfer.sh" ]]; then
    echo "$FREESURFER_HOME"; return 0
  fi
  local cand
  cand=$(ls -d /usr/local/freesurfer/[0-9]*/ 2>/dev/null | sed 's:/$::' | sort -V | tail -1)
  for d in "$cand" /usr/local/freesurfer /opt/freesurfer; do
    [[ -n "$d" && -f "$d/SetUpFreeSurfer.sh" ]] && { echo "$d"; return 0; }
  done
  return 1
}

# Source SetUpFreeSurfer.sh (idempotent). Keeps a caller-supplied SUBJECTS_DIR.
fs_setup() {
  local home keep_sd="${SUBJECTS_DIR:-}"
  home=$(fs_locate_home) || return 1
  export FREESURFER_HOME="$home"
  if ! command -v recon-all >/dev/null 2>&1 || [[ -z "${FS_SETUP_DONE:-}" ]]; then
    # SetUpFreeSurfer.sh references unset variables; relax nounset while sourcing
    set +u
    # shellcheck disable=SC1091
    source "$FREESURFER_HOME/SetUpFreeSurfer.sh" >/dev/null 2>&1
    set -u
    export FS_SETUP_DONE=1
  fi
  [[ -n "$keep_sd" ]] && export SUBJECTS_DIR="$keep_sd"
  return 0
}

fs_version() {
  local stamp="$FREESURFER_HOME/build-stamp.txt"
  if [[ -f "$stamp" ]]; then
    grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$stamp" | head -1
  elif command -v recon-all >/dev/null 2>&1; then
    recon-all -version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1
  fi
}

fs_major() { local v; v=$(fs_version); echo "${v%%.*}"; }

# FreeSurfer license: FS_LICENSE, license.txt / .license in FREESURFER_HOME,
# or /usr/local/freesurfer/license.txt (where install_ubuntu24.sh puts it)
fs_license_file() {
  local f
  for f in "${FS_LICENSE:-}" "$FREESURFER_HOME/license.txt" "$FREESURFER_HOME/.license" \
           /usr/local/freesurfer/license.txt /license.txt; do
    [[ -n "$f" && -s "$f" ]] && { echo "$f"; return 0; }
  done
  return 1
}

# MATLAB runtime needed by segmentHA_T1.sh / segmentBS.sh
# (install with: fs_install_mcr R2019b  -> $FREESURFER_HOME/MCRv97)
fs_mcr_dir() {
  local d
  d=$(ls -d "$FREESURFER_HOME"/MCRv* "$FREESURFER_HOME"/MCR_R* 2>/dev/null | sort -V | tail -1)
  [[ -n "$d" && -d "$d" ]] && { echo "$d"; return 0; }
  return 1
}

os_description() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    (. /etc/os-release; echo "${PRETTY_NAME:-$NAME $VERSION_ID}")
  else
    uname -sr
  fi
}

# Python interpreter that has MNE-Python (set up by setup.sh):
# $NEUROIMAGING_MNE_PYTHON, /opt/neuroimaging/venv, <project>/.venv, system python3
mne_python() {
  local root="${1:-}" p
  for p in "${NEUROIMAGING_MNE_PYTHON:-}" /opt/neuroimaging/venv/bin/python \
           ${root:+"$root/.venv/bin/python"} python3; do
    [[ -n "$p" ]] || continue
    command -v "$p" >/dev/null 2>&1 || continue
    "$p" -c 'import mne, nibabel' >/dev/null 2>&1 && { command -v "$p"; return 0; }
  done
  return 1
}

# Run a command with a virtual X display when none is available (MNE 3D)
with_display() {
  if [[ -n "${DISPLAY:-}" ]] || ! command -v xvfb-run >/dev/null 2>&1; then
    "$@"
  else
    xvfb-run -a -s "-screen 0 1600x1200x24" "$@"
  fi
}
