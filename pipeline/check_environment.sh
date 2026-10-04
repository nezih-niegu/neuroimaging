#!/usr/bin/env bash
# Report whether this machine can run the FreeSurfer pipeline.
#   pipeline/check_environment.sh          human-readable
#   pipeline/check_environment.sh --json   machine-readable (used by the app/API)
set -uo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/freesurfer_env.sh
source "$SCRIPT_DIR/lib/freesurfer_env.sh"

have() { command -v "$1" >/dev/null 2>&1 && echo true || echo false; }

os="$(os_description)"
ubuntu24=false
if [[ -r /etc/os-release ]]; then
  (. /etc/os-release; [[ "${ID:-}" == ubuntu && "${VERSION_ID:-}" == 24.04 ]]) && ubuntu24=true
fi
arch="$(uname -m)"

fs_home="" fs_ver="" license="" mcr="" recon=false segha=false
if fs_setup 2>/dev/null; then
  fs_home="$FREESURFER_HOME"
  fs_ver="$(fs_version)"
  license="$(fs_license_file || true)"
  mcr="$(fs_mcr_dir || true)"
  recon=$(have recon-all)
  segha=$(have segmentHA_T1.sh)
fi
pydicom=$(python3 -c 'import pydicom' >/dev/null 2>&1 && echo true || echo false)
mne_ver=""
if MNE_PY="$(mne_python "$(cd "$SCRIPT_DIR/.." && pwd)")"; then
  mne_ver="$("$MNE_PY" -c 'import mne; print(mne.__version__)' 2>/dev/null)"
fi
mne3d=false
if [[ -n "$mne_ver" ]] && "$MNE_PY" -c 'import pyvista, pyvistaqt' >/dev/null 2>&1 \
   && { [[ -n "${DISPLAY:-}" ]] || command -v xvfb-run >/dev/null 2>&1; }; then mne3d=true; fi
major="${fs_ver%%.*}"
ready=false
[[ "$recon" == true && -n "$license" && -n "$major" && "$major" -ge 7 ]] && ready=true

if [[ "${1:-}" == "--json" ]]; then
  python3 - "$os" "$ubuntu24" "$arch" "$fs_home" "$fs_ver" "$license" "$mcr" "$recon" "$segha" \
            "$(have dcm2niix)" "$pydicom" "$(have dcmdump)" "$(have Rscript)" "$ready" \
            "$mne_ver" "$mne3d" <<'PY'
import json, sys
a = sys.argv[1:]
b = lambda s: s == "true"
print(json.dumps({
  "os": a[0], "ubuntu_24_04": b(a[1]), "arch": a[2],
  "freesurfer_home": a[3] or None, "freesurfer_version": a[4] or None,
  "license_file": a[5] or None, "matlab_runtime": a[6] or None,
  "recon_all": b(a[7]), "segmentHA_T1": b(a[8]), "dcm2niix": b(a[9]),
  "pydicom": b(a[10]), "dcmdump": b(a[11]), "rscript": b(a[12]),
  "ready": b(a[13]), "mne_version": a[14] or None, "mne_3d": b(a[15]),
}))
PY
  exit 0
fi

mark() { [[ "$1" == true || ( "$1" != false && -n "$1" ) ]] && echo "  [ok]  " || echo "  [--]  "; }
echo "Neuroimaging pipeline environment"
echo "$(mark "$ubuntu24")OS: $os ($arch)$([[ $ubuntu24 == true ]] || echo '  - tested target is Ubuntu 24.04')"
echo "$(mark "$fs_home")FreeSurfer: ${fs_ver:-not found} ${fs_home:+($fs_home)}"
[[ -n "$major" && "$major" -lt 7 ]] && echo "        FreeSurfer $fs_ver is too old; install 8.x (install/install_ubuntu24.sh --freesurfer)"
echo "$(mark "$license")License: ${license:-missing - set FS_LICENSE=/path/to/license.txt}"
echo "$(mark "$mcr")MATLAB runtime (hippocampal/brainstem): ${mcr:-missing - run: sudo -E fs_install_mcr R2019b}"
echo "$(mark "$(have dcm2niix)")dcm2niix"
echo "$(mark "$pydicom")python3-pydicom (DICOM age/sex)"
echo "$(mark "$(have Rscript)")Rscript (report step)"
echo "$(mark "$mne_ver")MNE-Python (visualisation): ${mne_ver:-missing - run setup.sh}$([[ -n "$mne_ver" ]] && { [[ $mne3d == true ]] && echo '  3D: yes' || echo '  3D: no (needs pyvistaqt + xvfb)'; })"
echo
[[ "$ready" == true ]] && echo "READY to run pipeline/neuroimaging-pipeline.sh" || { echo "NOT READY - fix the [--] items above"; exit 1; }
