#!/usr/bin/env bash
# ===========================================================================
# install_ubuntu24.sh - install everything this project needs on Ubuntu 24.04
#
#   sudo install/install_ubuntu24.sh                        # app + DICOM tools
#   sudo install/install_ubuntu24.sh --freesurfer \
#        --license ~/license.txt --with-mcr                 # + FreeSurfer 8.2.0
#   sudo install/install_ubuntu24.sh --skip-app --mne      # + MNE-Python
#
# (For a complete one-command setup use ./setup.sh in the project root.)
#
# App part: R and every R package come from Ubuntu 24.04's own repositories
# (r-cran-*), so nothing is compiled. Also installs dcm2niix, pydicom, dcmtk.
#
# FreeSurfer part (x86_64 only): installs the official Ubuntu 24 package
#   https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/<ver>/freesurfer_ubuntu24-<ver>_amd64.deb
# into /usr/local/freesurfer/<ver>, writes /etc/profile.d/freesurfer.sh, and
# optionally the MATLAB runtime (R2019b) needed by segmentHA_T1.sh/segmentBS.sh.
#
# Options:
#   --freesurfer          also install FreeSurfer
#   --fs-version VER      FreeSurfer version (default 8.2.0)
#   --fs-deb FILE         use an already-downloaded .deb instead of downloading
#   --license FILE        FreeSurfer license.txt (free: surfer.nmr.mgh.harvard.edu/registration.html)
#   --with-mcr            install the MATLAB runtime (hippocampal subfields / brainstem)
#   --mne                 install MNE-Python (+ PyVista/Qt, Xvfb) for brain visualisation
#   --mne-venv DIR        where to create the MNE Python environment (default /opt/neuroimaging/venv)
#   --skip-app            only FreeSurfer
#   --force               continue on a non-24.04 system
# ===========================================================================
set -Eeuo pipefail

FS_VERSION="8.2.0" FS_DEB="" LICENSE="" WITH_FS=0 WITH_MCR=0 SKIP_APP=0 FORCE=0
WITH_MNE=0 MNE_VENV="/opt/neuroimaging/venv"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --freesurfer) WITH_FS=1; shift ;;
    --fs-version) FS_VERSION="$2"; shift 2 ;;
    --fs-deb)     FS_DEB="$2"; shift 2 ;;
    --license)    LICENSE="$2"; shift 2 ;;
    --with-mcr)   WITH_MCR=1; shift ;;
    --mne)        WITH_MNE=1; shift ;;
    --mne-venv)   MNE_VENV="$2"; shift 2 ;;
    --skip-app)   SKIP_APP=1; shift ;;
    --force)      FORCE=1; shift ;;
    -h|--help)    sed -n '2,36p' "$0"; exit 0 ;;
    *) echo "Unknown option $1" >&2; exit 2 ;;
  esac
done

say() { printf '\n==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "run with sudo"
export DEBIAN_FRONTEND=noninteractive

. /etc/os-release
if [[ "${ID:-}" != ubuntu || "${VERSION_ID:-}" != 24.04 ]]; then
  [[ $FORCE -eq 1 ]] || die "this installer targets Ubuntu 24.04 (found ${PRETTY_NAME:-unknown}); use --force to continue"
  echo "WARNING: not Ubuntu 24.04 - continuing because of --force"
fi

ensure_universe() {
  if ! grep -rqsE '^(Components:.*universe|deb .* universe)' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    apt-get install -y --no-install-recommends software-properties-common
    add-apt-repository -y universe
  fi
}

if [[ $SKIP_APP -eq 0 ]]; then
  say "Installing R, R packages and DICOM tools from the Ubuntu 24.04 archive"
  apt-get update
  ensure_universe
  apt-get update
  apt-get install -y --no-install-recommends \
    r-base-core \
    r-cran-shiny r-cran-dt r-cran-ggplot2 r-cran-dbi r-cran-rsqlite \
    r-cran-plumber r-cran-httr r-cran-jsonlite r-cran-gridextra r-cran-png \
    dcm2niix python3 python3-pydicom python3-numpy dcmtk \
    bc tcsh unzip curl ca-certificates fonts-dejavu-core
  Rscript -e 'pkgs <- c("shiny","DT","ggplot2","DBI","RSQLite","plumber","httr","jsonlite","gridExtra","png");
              ok <- vapply(pkgs, requireNamespace, logical(1), quietly = TRUE);
              if (!all(ok)) { message("Missing R packages: ", paste(pkgs[!ok], collapse=", ")); quit(status=1) };
              message("All R packages load.")'
fi

if [[ $WITH_FS -eq 1 ]]; then
  [[ "$(uname -m)" == x86_64 ]] || die "FreeSurfer's Ubuntu package is x86_64 only (this is $(uname -m))"
  say "Installing FreeSurfer $FS_VERSION (Ubuntu 24 package)"
  if [[ -z "$FS_DEB" ]]; then
    FS_DEB="/tmp/freesurfer_ubuntu24-${FS_VERSION}_amd64.deb"
    url="https://surfer.nmr.mgh.harvard.edu/pub/dist/freesurfer/${FS_VERSION}/freesurfer_ubuntu24-${FS_VERSION}_amd64.deb"
    if [[ ! -s "$FS_DEB" ]]; then
      echo "Downloading $url (several GB)..."
      curl -fL --retry 3 -o "$FS_DEB.part" "$url" && mv "$FS_DEB.part" "$FS_DEB"
    fi
  fi
  [[ -s "$FS_DEB" ]] || die "FreeSurfer package not found: $FS_DEB"
  apt-get update
  apt-get install -y "$(readlink -f "$FS_DEB")"

  FS_HOME="/usr/local/freesurfer/${FS_VERSION}"
  [[ -f "$FS_HOME/SetUpFreeSurfer.sh" ]] || FS_HOME="$(ls -d /usr/local/freesurfer/*/ 2>/dev/null | sed 's:/$::' | sort -V | tail -1)"
  [[ -f "$FS_HOME/SetUpFreeSurfer.sh" ]] || die "FreeSurfer installed but SetUpFreeSurfer.sh not found under /usr/local/freesurfer"

  # License lives outside the versioned tree so upgrades keep it
  if [[ -n "$LICENSE" ]]; then
    install -m 0644 "$LICENSE" /usr/local/freesurfer/license.txt
    echo "License installed to /usr/local/freesurfer/license.txt"
  fi

  cat > /etc/profile.d/freesurfer.sh <<EOF
# FreeSurfer ${FS_VERSION} (written by neuroimaging install_ubuntu24.sh)
export FREESURFER_HOME="${FS_HOME}"
[ -s /usr/local/freesurfer/license.txt ] && export FS_LICENSE=/usr/local/freesurfer/license.txt
[ -f "\$FREESURFER_HOME/SetUpFreeSurfer.sh" ] && . "\$FREESURFER_HOME/SetUpFreeSurfer.sh" >/dev/null 2>&1
EOF
  echo "Shell setup: /etc/profile.d/freesurfer.sh (open a new login shell to pick it up)"

  if [[ $WITH_MCR -eq 1 ]]; then
    say "Installing the MATLAB runtime R2019b for segmentHA_T1.sh / segmentBS.sh"
    (export FREESURFER_HOME="$FS_HOME"; set +u; . "$FS_HOME/SetUpFreeSurfer.sh" >/dev/null 2>&1; set -u
     fs_install_mcr R2019b)
  fi
fi

if [[ $WITH_MNE -eq 1 ]]; then
  say "Installing MNE-Python for brain visualisation ($MNE_VENV)"
  apt-get update
  # venv + Xvfb (virtual display for 3D rendering on servers) + the X/GL/Qt
  # runtime libraries PyVista and Qt need
  apt-get install -y --no-install-recommends \
    python3-venv python3-pip xvfb xauth \
    libgl1 libegl1 libglu1-mesa libosmesa6 libxrender1 libxkbcommon-x11-0 libxcb-cursor0 \
    libxcb-icccm4 libxcb-image0 libxcb-keysyms1 libxcb-render-util0 libxcb-shape0 \
    libxcb-xinerama0 libxcb-xkb1 libdbus-1-3 libfontconfig1
  # create the venv from the resolved interpreter so it stays usable by every
  # account (python3 may be a symlink into a private location)
  "$(readlink -f "$(command -v python3)")" -m venv --clear "$MNE_VENV"
  "$MNE_VENV/bin/pip" install --quiet --upgrade pip
  "$MNE_VENV/bin/pip" install --quiet \
    "mne>=1.8,<2" "nibabel>=5" "matplotlib>=3.7" "pyvista>=0.43" "pyvistaqt>=0.11" qtpy PySide6-Essentials
  "$MNE_VENV/bin/pip" freeze > "$MNE_VENV/requirements.lock"
  "$MNE_VENV/bin/python" -c 'import mne, nibabel, pyvista, pyvistaqt; print("MNE", mne.__version__, "/ PyVista", pyvista.__version__)'
fi

say "Environment check"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$SCRIPT_DIR/../pipeline/check_environment.sh" || true
