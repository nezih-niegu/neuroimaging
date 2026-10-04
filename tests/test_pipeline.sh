#!/usr/bin/env bash
# End-to-end test of pipeline/neuroimaging-pipeline.sh against a stub
# FreeSurfer 8 install + synthetic DICOMs (no real FreeSurfer needed).
#   tests/test_pipeline.sh
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
pass() { echo "PASS: $*"; }
fail() { echo "FAIL: $*"; exit 1; }

python3 "$ROOT/tests/make_fixtures.py" "$ROOT" "$T" >/dev/null
export FREESURFER_HOME="$T/freesurfer/8.2.0" NEUROIMAGING_DB_PATH="$T/patients.sqlite"
unset SUBJECTS_DIR NEUROIMAGING_SUBJECTS_DIR NEUROIMAGING_PROCESSED_DIR
# MNE-Python (if installed): the stub recon-all then also writes a synthetic
# anatomy (T1, white/pial surfaces, aparc) so the visualisation step runs for real
# shellcheck source=../pipeline/lib/freesurfer_env.sh
source "$ROOT/pipeline/lib/freesurfer_env.sh"
if MNE_PY="$(mne_python "$ROOT")"; then export NEUROIMAGING_TEST_MNE_PY="$MNE_PY"; else MNE_PY=""; fi

# 1) full run from DICOM, age/sex taken from the header
"$ROOT/pipeline/neuroimaging-pipeline.sh" --subject sub-t1 --dicom "$T/dicom" \
  --subjects-dir "$T/subjects" --output-dir "$T/out" --report > "$T/run1.log" 2>&1 \
  || { cat "$T/run1.log"; fail "pipeline run"; }
grep -q "Selected T1: t1_mprage_sag_2.nii.gz" "$T/run1.log" && pass "T1 chosen, contrast series rejected" || fail "T1 selection"
grep -q "Age: 66   Sex: M" "$T/run1.log" && pass "age/sex from DICOM" || fail "demographics"
for f in asegstats_vol lhaparc_vol rhaparc_thick lhaparc_area hipposubfield_vol brainstemstruct_vol; do
  [[ -s "$T/out/$f.txt" ]] || fail "missing $f.txt"
done; pass "stats tables written"
[[ -s "$T/out/sub-t1_report.pdf" ]] && pass "PDF written" || fail "PDF"
if [[ -n "$MNE_PY" ]]; then
  for f in mne_slices_coronal.png mne_slices_axial.png mne_slices_sagittal.png mne_report.html; do
    [[ -s "$T/out/qc/$f" ]] || { cat "$T/run1.log"; fail "MNE output $f missing"; }
  done; pass "MNE 2D figures + HTML report"
  if "$MNE_PY" -c 'import pyvistaqt' 2>/dev/null && { [[ -n "${DISPLAY:-}" ]] || command -v xvfb-run >/dev/null; }; then
    [[ -s "$T/out/qc/mne_aparc_3d.png" ]] && pass "MNE 3D parcellation render" || fail "MNE 3D render"
  fi
  grep -q "PDF includes [0-9] MNE figure" "$T/run1.log" && pass "MNE figures embedded in clinical PDF" || fail "PDF figures"
else
  echo "SKIP: MNE-Python not installed - visualisation not tested"
fi

# 2) re-run: recon-all must be skipped
"$ROOT/pipeline/neuroimaging-pipeline.sh" --subject sub-t1 --existing --age 66 \
  --subjects-dir "$T/subjects" --output-dir "$T/out" > "$T/run2.log" 2>&1 || { cat "$T/run2.log"; fail "rerun"; }
grep -q "already complete" "$T/run2.log" && pass "completed recon-all is not redone" || fail "resume"

# 3) R checks: harmonisation, native == tables, labels, DB contents
cd "$ROOT"
Rscript - "$T" <<'RS' || fail "R checks"
T <- commandArgs(TRUE)[1]
suppressMessages(source("global.R"))
nat <- read_subject_stats_dir(file.path(T, "subjects", "sub-t1"))
tab <- read_subject_stats_dir(file.path(T, "out"), "sub-t1")
ex  <- read_subject_stats_dir("examples/sample_subject")
chk <- function(ok, msg) { if (!isTRUE(ok)) { cat("FAIL:", msg, "\n"); quit(status = 1) }; cat("PASS:", msg, "\n") }
same <- function(a, b) isTRUE(all.equal(a[sort(names(a))], b[sort(names(b))]))
chk(all(mapply(same, nat, tab[names(nat)])), "native FreeSurfer reader == exported tables")
for (k in names(ex)) chk(same(ex[[k]], nat[[k]][names(ex[[k]])]) && all(names(ex[[k]]) %in% names(nat[[k]])),
                         paste("FS 8 output reproduces FS 6 table columns for", k))
chk(all(c("Left-Thalamus-Proper", "Right-Thalamus-Proper") %in% names(nat$seg_vol)), "Left-Thalamus -> Left-Thalamus-Proper")
chk(abs(nat$hippo_vol[["left_CA1"]] - 513.492081) < 1e-3, "hippocampal head+body summed to FS 6 subfield")
chk(!any(grepl("-head$|-body$|hippocampal_body", names(nat$hippo_vol))), "no FS 7+ only subfields left")
m <- load_or_build_models()
r <- build_full_report(nat, 66, m, NAMES_DIR)
chk(all(sapply(r, nrow) > 0), "report has rows for all 9 tables")
chk(r$hippo_vol$label[r$hippo_vol$region_key == "right_CA1"] == "Right CA1", "right-side labels")
chk(r$seg_vol$label[r$seg_vol$region_key == "Right-Thalamus-Proper"] == "Right Thalamus", "subcortical labels")
con <- db_connect(DB_PATH); p <- db_list_patients(con); DBI::dbDisconnect(con)
chk("sub-t1" %in% p$patient_id && p$age[p$patient_id == "sub-t1"] == 66, "patient stored in DB")
# reference cohorts: ages only from the scan's own cohort, IDs only as whole tokens
d <- load_reference_demographics(REFERENCE_DIR)
chk(is.null(match_demographics("/x/stats/ICBM_MNI_0110_MRI_T1-FFE_br_2005_S6739_I2242", d)),
    "ICBM scan never takes a PPMI subject's age")
chk(identical(match_demographics("PPMI_3053_MR_SAG_3D_T1", d)$Subject, "3053") &&
    identical(match_demographics("ADNI_002_S_6007_MR", d)$Subject, "002_S_6007"), "PPMI / ADNI ages matched")
rs <- reference_summary(REFERENCE_DIR)$summary
chk(all(c("ICBM", "PPMI", "ADNI") %in% rs$cohort) && rs$with_age_used[rs$cohort == "PPMI"] > 0, "cohort coverage report")
RS
echo "ALL PIPELINE TESTS PASSED"
