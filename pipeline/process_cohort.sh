#!/usr/bin/env bash
# ===========================================================================
# process_cohort.sh - run the FreeSurfer pipeline on a whole CONTROL cohort
# (ICBM, PPMI, ADNI, or your own) and file the results as reference data.
#
#   pipeline/process_cohort.sh --cohort PPMI --dicom-root /data/PPMI_dicom \
#       --demographics /data/PPMI_T1_controls.csv [--threads 4] [--parallel 2]
#
# --dicom-root holds ONE SUBFOLDER PER SUBJECT (any depth of DICOMs inside):
#     /data/PPMI_dicom/3053/...       /data/PPMI_dicom/3055/...
# Each subject becomes "<COHORT>_<folder>" (e.g. PPMI_3053) unless the
# folder name already starts with the cohort name.
#
# Output (default reference dir = data/reference/batches_fs8):
#     <ref>/<COHORT>/<COHORT>_demographics.csv        (copy of --demographics)
#     <ref>/<COHORT>/<subject>/asegstats_vol.txt ... (per-subject tables)
#
# The demographics CSV needs "Subject" and "Age" columns (Sex optional);
# Subject must match the folder name / scan ID (e.g. 3053, 002_S_0096, MNI_0103).
# LONI IDA "collection" CSV exports for PPMI/ADNI/ICBM work as-is.
#
# Already-finished subjects are skipped, so the command can be re-run after an
# interruption. When done, point the app at the new reference:
#     NEUROIMAGING_REFERENCE_DIR=data/reference/batches_fs8   (setup.conf: REFERENCE_DIR=)
#     neuroimaging reference --rebuild
# ===========================================================================
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=lib/freesurfer_env.sh
source "$SCRIPT_DIR/lib/freesurfer_env.sh"

COHORT="" ROOT="" DEMO="" REF="$PROJECT_ROOT/data/reference/batches_fs8"
THREADS=4 PARALLEL=1 EXTRA=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --cohort)        COHORT="$2"; shift 2 ;;
    --dicom-root)    ROOT="$2"; shift 2 ;;
    --demographics)  DEMO="$2"; shift 2 ;;
    --reference-dir) REF="$2"; shift 2 ;;
    --threads)       THREADS="$2"; shift 2 ;;
    --parallel)      PARALLEL="$2"; shift 2 ;;
    --no-subregions|--force) EXTRA+=("$1"); shift ;;
    -h|--help)       sed -n '2,30p' "$0"; exit 0 ;;
    *) die "unknown option $1 (see --help)" ;;
  esac
done
[[ "$COHORT" =~ ^[A-Za-z][A-Za-z0-9]*$ ]] || die "--cohort NAME is required (letters/digits, e.g. ICBM, PPMI, ADNI)"
COHORT="${COHORT^^}"
[[ -d "$ROOT" ]] || die "--dicom-root folder not found: $ROOT"
[[ -f "$DEMO" ]] || die "--demographics CSV not found: $DEMO"
head -1 "$DEMO" | grep -q 'Subject' && head -1 "$DEMO" | grep -q 'Age' \
  || die "the demographics CSV needs 'Subject' and 'Age' columns"
[[ "$THREADS" =~ ^[0-9]+$ && "$PARALLEL" =~ ^[0-9]+$ ]] || die "--threads/--parallel must be integers"

OUT="$REF/$COHORT"
mkdir -p "$OUT" "$OUT/.logs"
cp "$DEMO" "$OUT/${COHORT}_demographics.csv"
SD="${NEUROIMAGING_SUBJECTS_DIR:-${SUBJECTS_DIR:-$PROJECT_ROOT/data/freesurfer_subjects}}"

mapfile -t FOLDERS < <(find "$ROOT" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
[[ ${#FOLDERS[@]} -gt 0 ]] || die "no subject subfolders in $ROOT"
log "Cohort $COHORT: ${#FOLDERS[@]} subject folder(s) -> $OUT  (parallel=$PARALLEL, threads each=$THREADS)"

run_one() {
  local folder="$1" subj
  subj="${folder//[^A-Za-z0-9._-]/_}"
  shopt -s nocasematch
  [[ "$subj" == "${COHORT}"_* ]] || subj="${COHORT}_${subj}"
  shopt -u nocasematch
  if [[ -s "$OUT/$subj/asegstats_vol.txt" && -s "$OUT/$subj/lhaparc_thick.txt" ]]; then
    echo "skip   $subj (already done)"; return 0
  fi
  if "$SCRIPT_DIR/neuroimaging-pipeline.sh" --subject "$subj" --dicom "$ROOT/$folder" \
       --subjects-dir "$SD" --output-dir "$OUT/$subj" --threads "$THREADS" --no-mne \
       ${EXTRA[@]+"${EXTRA[@]}"} > "$OUT/.logs/$subj.log" 2>&1; then
    rm -rf "$OUT/$subj/work"
    echo "ok     $subj"
  else
    echo "FAILED $subj (log: $OUT/.logs/$subj.log)"
  fi
}
export -f run_one log
export SCRIPT_DIR OUT ROOT COHORT SD THREADS
export EXTRA_STR="${EXTRA[*]-}"

# shellcheck disable=SC2016
printf '%s\n' "${FOLDERS[@]}" | xargs -d '\n' -P "$PARALLEL" -I{} bash -c '
  read -r -a EXTRA <<< "$EXTRA_STR"; run_one "$1"' _ {} | tee "$OUT/.logs/summary.txt"

ok=$(grep -c '^ok\|^skip' "$OUT/.logs/summary.txt" || true)
bad=$(grep -c '^FAILED' "$OUT/.logs/summary.txt" || true)
log "Done: $ok subject(s) ready, $bad failed. Next:"
echo "    NEUROIMAGING_REFERENCE_DIR=$REF $PROJECT_ROOT/bin/neuroimaging reference --rebuild"
