#!/usr/bin/env bash
# (Re)generate the MNE-Python visual QC for a FreeSurfer subject that has
# already been processed (pipeline step 6 on its own).
#
#   pipeline/visualize.sh --subject ID [--subjects-dir DIR] [--out-dir DIR] [--no-3d] [--bem]
#
# Output (default data/processed/ID/qc/): mne_slices_{coronal,axial,sagittal}.png,
# mne_aparc_3d.png, mne_report.html, mne_qc.json
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/freesurfer_env.sh
source "$SCRIPT_DIR/lib/freesurfer_env.sh"

SUBJECT="" SD="" OUT="" ARGS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject)      SUBJECT="$2"; shift 2 ;;
    --subjects-dir) SD="$2"; shift 2 ;;
    --out-dir)      OUT="$2"; shift 2 ;;
    --no-3d)        ARGS+=(--no-3d); shift ;;
    --bem)          ARGS+=(--bem); shift ;;
    -h|--help)      sed -n '2,9p' "$0"; exit 0 ;;
    *) die "Unknown argument: $1" ;;
  esac
done
[[ "$SUBJECT" =~ ^[A-Za-z0-9._-]+$ ]] || die "--subject is required (letters, digits, . _ -)"
SD="${SD:-${NEUROIMAGING_SUBJECTS_DIR:-${SUBJECTS_DIR:-$PROJECT_ROOT/data/freesurfer_subjects}}}"
OUT="${OUT:-${NEUROIMAGING_PROCESSED_DIR:-$PROJECT_ROOT/data/processed}/$SUBJECT/qc}"
[[ -d "$SD/$SUBJECT" ]] || die "subject not found: $SD/$SUBJECT"

# --bem uses FreeSurfer's mri_watershed through MNE
if [[ " ${ARGS[*]-} " == *" --bem "* ]]; then
  fs_setup || die "--bem needs FreeSurfer (mri_watershed)"
  export SUBJECTS_DIR="$SD"
fi
MNE_PY="$(mne_python "$PROJECT_ROOT")" || die "MNE-Python not found - run setup.sh (or set NEUROIMAGING_MNE_PYTHON)"
mkdir -p "$OUT"
with_display "$MNE_PY" "$SCRIPT_DIR/lib/mne_visualize.py" --subjects-dir "$SD" --subject "$SUBJECT" \
  --out-dir "$OUT" ${ARGS[@]+"${ARGS[@]}"}
