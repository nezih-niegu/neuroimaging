#!/usr/bin/env bash
# ===========================================================================
# neuroimaging-pipeline.sh - FreeSurfer processing for ONE subject, from
# DICOMs (or a T1 NIfTI) to the normative percentile report.
#
# Replaces legacy/recon_report.sh. Targets FreeSurfer 7.x / 8.x and is
# tested against the Ubuntu 24.04 package (freesurfer_ubuntu24-8.x).
#
#   1. demographics   age/sex read from the DICOM header (or --age/--sex)
#   2. dcm2niix       DICOM -> NIfTI, then pick the structural T1
#   3. recon-all      full cortical reconstruction (skipped if already done)
#   4. subregions     segmentHA_T1.sh + segmentBS.sh (FS >= 7 replacements for
#                     recon-all -hippocampal-subfields-T1 / -brainstem-structures)
#   5. tables         asegstats2table / aparcstats2table + subregion tables
#                     (legacy-compatible *.txt files, uploadable in the app)
#   6. visualisation  MNE-Python visual QC: white/pial surfaces over T1 slices,
#                     3D aparc parcellation, HTML report (output_dir/qc/)
#   7. report         percentile-for-age report -> patient DB + clinical PDF
#                     (only with --report; uses the R code in R/; includes the
#                     MNE figures)
#
# Example:
#   pipeline/neuroimaging-pipeline.sh --subject sub-001 --dicom /data/dicom/sub-001 --report
# ===========================================================================
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/freesurfer_env.sh
source "$SCRIPT_DIR/lib/freesurfer_env.sh"

usage() {
  cat <<EOF
Usage: $(basename "$0") --subject ID (--dicom DIR | --t1 FILE | --existing) [options]

Input (one of):
  --dicom DIR          DICOM folder of the session (any depth)
  --t1 FILE            T1-weighted NIfTI/MGZ to use directly
  --existing           subject already exists in SUBJECTS_DIR; skip conversion

Options:
  --subject ID         subject / patient identifier (letters, digits, . _ -)
  --age YEARS          patient age (default: read from DICOM header)
  --sex M|F            patient sex (default: read from DICOM header)
  --subjects-dir DIR   FreeSurfer SUBJECTS_DIR
                       (default: \$NEUROIMAGING_SUBJECTS_DIR, \$SUBJECTS_DIR, or data/freesurfer_subjects)
  --output-dir DIR     where stats tables / report go (default: data/processed/ID)
  --threads N          threads for recon-all (default: $(nproc 2>/dev/null || echo 1))
  --no-subregions      skip hippocampal subfields + brainstem segmentation
  --force              re-run recon-all even if the subject is already complete
  --report             compute the percentile report, save to the patient DB, write PDF
  --no-mne             skip the MNE-Python visualisation step
  --no-3d              MNE: only 2D slice figures (no 3D render)
  --bem                MNE: also build BEM surfaces (watershed) and draw them on the slices
  --api URL            with --report: submit through a running API instead of locally
  -h, --help           show this help
EOF
}

# ---- arguments -------------------------------------------------------------
SUBJECT="" DICOM_DIR="" T1_FILE="" EXISTING=0 AGE="" SEX=""
SUBJECTS_DIR_ARG="" OUTPUT_DIR="" THREADS="$(nproc 2>/dev/null || echo 1)"
DO_SUBREGIONS=1 FORCE=0 DO_REPORT=0 API_URL="" DO_MNE=1 MNE_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subject)       SUBJECT="$2"; shift 2 ;;
    --dicom)         DICOM_DIR="$2"; shift 2 ;;
    --t1)            T1_FILE="$2"; shift 2 ;;
    --existing)      EXISTING=1; shift ;;
    --age)           AGE="$2"; shift 2 ;;
    --sex)           SEX="$2"; shift 2 ;;
    --subjects-dir)  SUBJECTS_DIR_ARG="$2"; shift 2 ;;
    --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
    --threads)       THREADS="$2"; shift 2 ;;
    --no-subregions) DO_SUBREGIONS=0; shift ;;
    --force)         FORCE=1; shift ;;
    --report)        DO_REPORT=1; shift ;;
    --api)           API_URL="$2"; shift 2 ;;
    --no-mne)        DO_MNE=0; shift ;;
    --no-3d)         MNE_ARGS+=(--no-3d); shift ;;
    --bem)           MNE_ARGS+=(--bem); shift ;;
    -h|--help)       usage; exit 0 ;;
    *) usage >&2; die "Unknown argument: $1" ;;
  esac
done

[[ -n "$SUBJECT" ]] || { usage >&2; die "--subject is required"; }
[[ "$SUBJECT" =~ ^[A-Za-z0-9._-]+$ ]] || die "--subject may only contain letters, digits, '.', '_' and '-'"
n_inputs=$(( (${#DICOM_DIR} > 0) + (${#T1_FILE} > 0) + EXISTING ))
[[ $n_inputs -eq 1 ]] || { usage >&2; die "give exactly one of --dicom, --t1, --existing"; }
[[ -z "$DICOM_DIR" || -d "$DICOM_DIR" ]] || die "DICOM folder not found: $DICOM_DIR"
[[ -z "$T1_FILE" || -f "$T1_FILE" ]] || die "T1 file not found: $T1_FILE"
[[ -z "$SEX" || "$SEX" =~ ^[MF]$ ]] || die "--sex must be M or F"
[[ "$THREADS" =~ ^[0-9]+$ ]] || die "--threads must be an integer"

SD="${SUBJECTS_DIR_ARG:-${NEUROIMAGING_SUBJECTS_DIR:-${SUBJECTS_DIR:-$PROJECT_ROOT/data/freesurfer_subjects}}}"
mkdir -p "$SD"
SD="$(cd "$SD" && pwd)"
export SUBJECTS_DIR="$SD"
OUTPUT_DIR="${OUTPUT_DIR:-$PROJECT_ROOT/data/processed/$SUBJECT}"
mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
WORK_DIR="$OUTPUT_DIR/work"
mkdir -p "$WORK_DIR"

step() { log "== STEP $1/7: $2 =="; }
trap 'warn "pipeline failed at line $LINENO (exit $?)"' ERR

# ---- environment -----------------------------------------------------------
fs_setup || die "FreeSurfer not found. Install it with install/install_ubuntu24.sh --freesurfer, or set FREESURFER_HOME."
export SUBJECTS_DIR="$SD"   # SetUpFreeSurfer.sh may have reset it
FS_VER="$(fs_version)"
FS_MAJOR="${FS_VER%%.*}"
log "OS:              $(os_description)"
log "FreeSurfer:      ${FS_VER:-unknown} ($FREESURFER_HOME)"
log "SUBJECTS_DIR:    $SUBJECTS_DIR"
log "Output dir:      $OUTPUT_DIR"
[[ -n "$FS_MAJOR" && "$FS_MAJOR" -ge 7 ]] || die "FreeSurfer >= 7 is required (found '${FS_VER:-unknown}'). On Ubuntu 24.04 use FreeSurfer 8.x."
LICENSE="$(fs_license_file)" || die "No FreeSurfer license. Get one at https://surfer.nmr.mgh.harvard.edu/registration.html and set FS_LICENSE=/path/to/license.txt"
export FS_LICENSE="$LICENSE"
command -v recon-all >/dev/null || die "recon-all not on PATH after sourcing SetUpFreeSurfer.sh"

# ---- 1. demographics -------------------------------------------------------
step 1 "demographics"
if [[ -n "$DICOM_DIR" && ( -z "$AGE" || -z "$SEX" ) ]]; then
  DEMO_JSON="$(python3 "$SCRIPT_DIR/lib/dicom_demographics.py" "$DICOM_DIR" || true)"
  log "DICOM header: $DEMO_JSON"
  if [[ -z "$AGE" ]]; then
    AGE="$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get("age"); print("" if v is None else v)' "$DEMO_JSON" 2>/dev/null || true)"
  fi
  if [[ -z "$SEX" ]]; then
    SEX="$(python3 -c 'import json,sys; v=json.loads(sys.argv[1]).get("sex"); print(v or "")' "$DEMO_JSON" 2>/dev/null || true)"
  fi
fi
[[ -z "$AGE" || "$AGE" =~ ^[0-9]+([.][0-9]+)?$ ]] || die "invalid age '$AGE'"
log "Age: ${AGE:-unknown}   Sex: ${SEX:-unknown}"
if [[ $DO_REPORT -eq 1 && -z "$AGE" ]]; then
  die "Age could not be read from the DICOM header; pass --age"
fi

# ---- 2. DICOM -> NIfTI, choose T1 ------------------------------------------
step 2 "DICOM conversion / T1 selection"
SUBJ_PATH="$SUBJECTS_DIR/$SUBJECT"
if [[ -n "$DICOM_DIR" ]]; then
  command -v dcm2niix >/dev/null || die "dcm2niix not found (sudo apt install dcm2niix)"
  NIFTI_DIR="$WORK_DIR/nifti"
  rm -rf "$NIFTI_DIR"; mkdir -p "$NIFTI_DIR"
  dcm2niix -z y -b y -ba y -f '%p_%s' -o "$NIFTI_DIR" "$DICOM_DIR" > "$WORK_DIR/dcm2niix.log" 2>&1 \
    || { tail -20 "$WORK_DIR/dcm2niix.log" >&2; die "dcm2niix failed"; }

  # Pick the heaviest T1-weighted series, excluding contrast-enhanced,
  # localizers and scanner-derived reformats (same rule as legacy
  # recon_report.sh, extended to more vendor protocol names).
  T1_FILE=""
  best_size=0
  shopt -s nullglob nocaseglob
  for f in "$NIFTI_DIR"/*.nii.gz "$NIFTI_DIR"/*.nii; do
    name="$(basename "$f")"
    shopt -s nocasematch
    [[ "$name" =~ (t1|mprage|mp-rage|spgr|bravo|tfl3d|ir-fspgr) ]] || { shopt -u nocasematch; continue; }
    if [[ "$name" =~ (gd|gado|gadolinio|contrast|post|localizer|scout|survey|_ph\.|_real|_imaginary) ]]; then
      shopt -u nocasematch; continue
    fi
    shopt -u nocasematch
    json="${f%.nii.gz}"; json="${json%.nii}.json"
    if [[ -f "$json" ]] && grep -q '"DERIVED"' "$json"; then continue; fi
    size=$(stat -c %s "$f")
    if (( size > best_size )); then best_size=$size; T1_FILE="$f"; fi
  done
  shopt -u nullglob nocaseglob
  [[ -n "$T1_FILE" ]] || { ls -1 "$NIFTI_DIR" >&2; die "no T1-weighted series found among the converted series above; pass --t1 explicitly"; }
  log "Selected T1: $(basename "$T1_FILE")"
elif [[ -n "$T1_FILE" ]]; then
  T1_FILE="$(cd "$(dirname "$T1_FILE")" && pwd)/$(basename "$T1_FILE")"
  log "Using T1: $T1_FILE"
else
  [[ -d "$SUBJ_PATH" ]] || die "--existing given but $SUBJ_PATH does not exist"
  log "Using existing subject $SUBJ_PATH"
fi

# ---- 3. recon-all ----------------------------------------------------------
step 3 "recon-all (several hours)"
if [[ -f "$SUBJ_PATH/scripts/recon-all.done" && -f "$SUBJ_PATH/stats/aseg.stats" && $FORCE -eq 0 ]]; then
  log "recon-all already complete for $SUBJECT - skipping (use --force to redo)"
elif [[ -d "$SUBJ_PATH/mri/orig" && -n "$(ls -A "$SUBJ_PATH/mri/orig" 2>/dev/null)" ]]; then
  rm -f "$SUBJ_PATH/scripts/IsRunning".* 2>/dev/null || true
  log "Resuming/redoing recon-all on existing subject"
  recon-all -all -s "$SUBJECT" -sd "$SUBJECTS_DIR" -threads "$THREADS"
else
  [[ -n "$T1_FILE" ]] || die "no T1 available to start recon-all"
  [[ -d "$SUBJ_PATH" ]] && rm -rf "$SUBJ_PATH"   # empty/half-created folder blocks -i
  recon-all -all -s "$SUBJECT" -i "$T1_FILE" -sd "$SUBJECTS_DIR" -threads "$THREADS"
fi
[[ -f "$SUBJ_PATH/stats/aseg.stats" ]] || die "recon-all finished without stats/aseg.stats - check $SUBJ_PATH/scripts/recon-all.log"

# ---- 4. hippocampal subfields + brainstem ----------------------------------
step 4 "hippocampal subfields + brainstem"
if [[ $DO_SUBREGIONS -eq 1 ]]; then
  if ! MCR="$(fs_mcr_dir)"; then
    warn "MATLAB runtime not installed - skipping hippocampal/brainstem segmentation."
    warn "Install it once with:  sudo -E fs_install_mcr R2019b"
  else
    log "MATLAB runtime: $MCR"
    if [[ $FORCE -eq 0 ]] && ls "$SUBJ_PATH"/mri/lh.hippoSfVolumes-T1.v*.txt >/dev/null 2>&1; then
      log "hippocampal subfields already present - skipping"
    else
      segmentHA_T1.sh "$SUBJECT" "$SUBJECTS_DIR" || warn "segmentHA_T1.sh failed - report will omit hippocampal subfields"
    fi
    if [[ $FORCE -eq 0 ]] && ls "$SUBJ_PATH"/mri/brainstemSsVolumes.v*.txt >/dev/null 2>&1; then
      log "brainstem structures already present - skipping"
    else
      segmentBS.sh "$SUBJECT" "$SUBJECTS_DIR" || warn "segmentBS.sh failed - report will omit brainstem structures"
    fi
  fi
else
  log "skipped (--no-subregions)"
fi

# ---- 5. stats tables -------------------------------------------------------
step 5 "stats tables"
tables_ok=1
(
  cd "$OUTPUT_DIR"
  asegstats2table --subjects "$SUBJECT" --meas volume --tablefile asegstats_vol.txt
  for hemi in lh rh; do
    aparcstats2table --subjects "$SUBJECT" --hemi "$hemi" --meas volume    --parc aparc --tablefile "${hemi}aparc_vol.txt"
    aparcstats2table --subjects "$SUBJECT" --hemi "$hemi" --meas thickness --parc aparc --tablefile "${hemi}aparc_thick.txt"
    aparcstats2table --subjects "$SUBJECT" --hemi "$hemi" --meas area      --parc aparc --tablefile "${hemi}aparc_area.txt"
  done
) > "$WORK_DIR/stats2table.log" 2>&1 || tables_ok=0

if [[ $tables_ok -eq 0 ]]; then
  warn "FreeSurfer *stats2table tools failed (see $WORK_DIR/stats2table.log); writing tables with the app's native reader"
  command -v Rscript >/dev/null || die "Rscript not available for the fallback table export"
  Rscript "$PROJECT_ROOT/bin/export_tables.R" "$SUBJ_PATH" "$SUBJECT" "$OUTPUT_DIR"
else
  python3 "$SCRIPT_DIR/lib/collect_subregions.py" "$SUBJECTS_DIR" "$SUBJECT" "$OUTPUT_DIR" \
    || warn "some subregion tables are missing (see warnings above)"
fi
log "Tables written to $OUTPUT_DIR:"
ls -1 "$OUTPUT_DIR"/*.txt | sed 's/^/    /'

# run metadata (provenance for the report)
python3 - "$OUTPUT_DIR/pipeline_run.json" <<PY
import json, sys, datetime
json.dump({
  "subject": "$SUBJECT", "age": "${AGE}" or None, "sex": "${SEX}" or None,
  "freesurfer_version": "${FS_VER}", "freesurfer_home": "$FREESURFER_HOME",
  "os": "$(os_description)", "subjects_dir": "$SUBJECTS_DIR",
  "t1": "${T1_FILE}" or None, "finished": datetime.datetime.now().isoformat(timespec="seconds"),
}, open(sys.argv[1], "w"), indent=2)
PY

# ---- 6. MNE visualisation --------------------------------------------------
if [[ $DO_MNE -eq 1 ]]; then
  step 6 "MNE-Python visualisation"
  if MNE_PY="$(mne_python "$PROJECT_ROOT")"; then
    with_display "$MNE_PY" "$SCRIPT_DIR/lib/mne_visualize.py" --subjects-dir "$SUBJECTS_DIR" \
      --subject "$SUBJECT" --out-dir "$OUTPUT_DIR/qc" ${MNE_ARGS[@]+"${MNE_ARGS[@]}"} \
      || warn "MNE visualisation failed - see messages above (the report is unaffected)"
  else
    warn "MNE-Python not found - skipping visualisation (run setup.sh, or set NEUROIMAGING_MNE_PYTHON)"
  fi
else
  log "== STEP 6/7: MNE visualisation skipped (--no-mne) =="
fi

# ---- 7. report -------------------------------------------------------------
step 7 "percentile report"
if [[ $DO_REPORT -eq 1 ]]; then
  command -v Rscript >/dev/null || die "Rscript not found - install the app (install/install_ubuntu24.sh)"
  args=(--subject-dir "$SUBJ_PATH" --patient-id "$SUBJECT" --age "$AGE"
        --pdf "$OUTPUT_DIR/${SUBJECT}_report.pdf" --qc-dir "$OUTPUT_DIR/qc"
        --notes "FreeSurfer ${FS_VER} pipeline run $(date +%F)")
  [[ -n "$SEX" ]] && args+=(--sex "$SEX")
  [[ -n "$API_URL" ]] && args+=(--api "$API_URL")
  Rscript "$PROJECT_ROOT/bin/ingest_subject.R" "${args[@]}"
else
  log "skipped (pass --report to compute the report and store the patient)"
fi

log "DONE: $SUBJECT"
