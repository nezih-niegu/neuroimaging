#!/usr/bin/env python3
"""Build test fixtures for the pipeline test (tests/test_pipeline.sh).

  * a stub FreeSurfer 8 install (FREESURFER_HOME) whose recon-all /
    segmentHA_T1.sh / segmentBS.sh write outputs in the real FS 7/8 formats
    (aseg.stats with "Left-Thalamus", ?h.aparc.stats, head/body hippocampal
    subfields v22, brainstem v13), using values from examples/sample_subject
    and one reference-cohort subject;
  * a small synthetic DICOM session (a T1 MPRAGE series, a post-contrast T1
    and a localizer) so dcm2niix conversion, T1 selection and age/sex
    extraction run for real.

Usage: make_fixtures.py <project_root> <out_dir>
"""
import csv
import os
import stat
import sys

ROOT, OUT = sys.argv[1], sys.argv[2]
EX = os.path.join(ROOT, "examples", "sample_subject")
REF = os.path.join(ROOT, "data", "reference", "batches", "PPMI")


def read_table(path, sep="\t"):
    with open(path) as fh:
        rows = [l.rstrip("\n").split(sep) for l in fh if l.strip()]
    return dict(zip(rows[0][1:], rows[1][1:]))


def write_exec(path, text):
    with open(path, "w") as fh:
        fh.write(text)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


# ---------- stats contents in native FreeSurfer format ----------
fx = os.path.join(OUT, "fs_outputs")
os.makedirs(fx, exist_ok=True)

aseg = read_table(os.path.join(EX, "asegstats_vol.txt"))
with open(os.path.join(fx, "aseg.stats"), "w") as fh:
    fh.write("# Title Segmentation Statistics\n# generating_program mri_segstats\n")
    for meas in ("lhCortexVol", "rhCortexVol", "CortexVol", "lhCerebralWhiteMatterVol", "rhCerebralWhiteMatterVol",
                 "CerebralWhiteMatterVol", "SubCortGrayVol", "TotalGrayVol", "BrainSegVol", "SupraTentorialVol"):
        if meas in aseg:
            fh.write("# Measure %s, %s, %s, %s, mm^3\n" % (meas.replace("Vol", ""), meas, meas, aseg[meas]))
    fh.write("# Measure EstimatedTotalIntraCranialVol, eTIV, Estimated Total Intracranial Volume, 1520000.0, mm^3\n")
    fh.write("# ColHeaders  Index SegId NVoxels Volume_mm3 StructName normMean normStdDev normMin normMax normRange\n")
    i = 0
    for name, vol in aseg.items():
        if any(k in name for k in ("BrainSeg", "eTIV", "Mask", "Supra", "SurfaceHoles", "Cortex", "CerebralWhite", "SubCortGray", "TotalGray")) \
                and "Cerebellum" not in name:
            continue
        i += 1
        name = name.replace("Thalamus-Proper", "Thalamus")  # FS >= 7 naming
        fh.write("%3d %4d %8d %10s  %-35s 80.0 10.0 30.0 110.0 80.0\n" % (i, i, int(float(vol)), vol, name))

for hemi in ("lh", "rh"):
    vol = read_table(os.path.join(EX, hemi + "aparc_vol.txt"))
    thk = read_table(os.path.join(EX, hemi + "aparc_thick.txt"))
    area = read_table(os.path.join(EX, hemi + "aparc_area.txt"))
    with open(os.path.join(fx, hemi + ".aparc.stats"), "w") as fh:
        fh.write("# Table of FreeSurfer cortical parcellation anatomical statistics\n")
        fh.write("# Measure Cortex, NumVert, Number of Vertices, 150000, unitless\n")
        fh.write("# Measure Cortex, WhiteSurfArea, White Surface Total Area, 87049.5, mm^2\n")
        fh.write("# Measure Cortex, MeanThickness, Mean Thickness, %s, mm\n" % thk["%s_MeanThickness_thickness" % hemi])
        fh.write("# ColHeaders StructName NumVert SurfArea GrayVol ThickAvg ThickStd MeanCurv GausCurv FoldInd CurvInd\n")
        for k, v in vol.items():
            if not k.endswith("_volume"):
                continue
            region = k[len(hemi) + 1:-len("_volume")]
            t = thk.get("%s_%s_thickness" % (hemi, region))
            a = area.get("%s_%s_area" % (hemi, region))
            if t is None or a is None:
                continue
            fh.write("%-40s %6d %6s %6s %6s 0.500 0.110 0.020 10 1.5\n" % (region, 1000, a, v, t))

# hippocampal subfields: take reference subject's FS6 values, split into head/body like FS >= 7
hip = read_table(os.path.join(REF, "batch1_hippo.txt"), sep=" ")
split = ("subiculum", "CA1", "CA3", "CA4", "presubiculum", "molecular_layer_HP", "GC-ML-DG")
for side, hemi in (("left_", "lh"), ("right_", "rh")):
    with open(os.path.join(fx, hemi + ".hippoSfVolumes-T1.v22.txt"), "w") as fh:
        for k, v in hip.items():
            if not k.startswith(side):
                continue
            base, v = k[len(side):], float(v)
            if base in split:
                fh.write("%s-head %.6f\n%s-body %.6f\n" % (base, v * 0.6, base, v * 0.4))
            else:
                fh.write("%s %.6f\n" % (base, v))
        fh.write("Whole_hippocampal_body 1100.0\nWhole_hippocampal_head 1700.0\n")
bs = read_table(os.path.join(REF, "batch1_brainstem.txt"), sep=" ")
with open(os.path.join(fx, "brainstemSsVolumes.v13.txt"), "w") as fh:
    for k, v in bs.items():
        fh.write("%s %s\n" % (k, v))

# ---------- stub FreeSurfer 8 install ----------
fsh = os.path.join(OUT, "freesurfer", "8.2.0")
fbin = os.path.join(fsh, "bin")
os.makedirs(fbin, exist_ok=True)
os.makedirs(os.path.join(fsh, "MCRv97"), exist_ok=True)
open(os.path.join(fsh, "build-stamp.txt"), "w").write("freesurfer-linux-ubuntu24_x86_64-8.2.0-20260301-test\n")
open(os.path.join(fsh, "license.txt"), "w").write("test-license\n")
open(os.path.join(fsh, "SetUpFreeSurfer.sh"), "w").write(
    'export PATH="%s:$PATH"\nexport SUBJECTS_DIR="${SUBJECTS_DIR:-%s/subjects}"\n' % (fbin, fsh))

write_exec(os.path.join(fbin, "recon-all"), r'''#!/usr/bin/env bash
# stub recon-all: records its arguments and writes FS 8-format stats
set -e
echo "stub recon-all $*"
while [[ $# -gt 0 ]]; do
  case "$1" in -s) S="$2"; shift 2;; -sd) SD="$2"; shift 2;; -i) I="$2"; shift 2;; *) shift;; esac
done
SD="${SD:-$SUBJECTS_DIR}"
mkdir -p "$SD/$S"/{stats,mri/orig,scripts}
[[ -n "$I" ]] && { [[ -f "$I" ]] || { echo "input $I missing"; exit 1; }; cp "$I" "$SD/$S/mri/orig/input.nii.gz"; }
cp "FIXDIR"/aseg.stats "FIXDIR"/lh.aparc.stats "FIXDIR"/rh.aparc.stats "$SD/$S/stats/"
if [[ -n "${NEUROIMAGING_TEST_MNE_PY:-}" ]]; then
  "$NEUROIMAGING_TEST_MNE_PY" "ROOTDIR/tests/make_fake_anatomy.py" "$SD/$S" >/dev/null
fi
touch "$SD/$S/scripts/recon-all.done"
'''.replace("FIXDIR", fx).replace("ROOTDIR", os.path.abspath(ROOT)))
write_exec(os.path.join(fbin, "segmentHA_T1.sh"),
           '#!/usr/bin/env bash\necho "stub segmentHA_T1.sh $*"\ncp "%s"/?h.hippoSfVolumes-T1.v22.txt "$2/$1/mri/"\n' % fx)
write_exec(os.path.join(fbin, "segmentBS.sh"),
           '#!/usr/bin/env bash\necho "stub segmentBS.sh $*"\ncp "%s"/brainstemSsVolumes.v13.txt "$2/$1/mri/"\n' % fx)
# asegstats2table/aparcstats2table intentionally absent in "fallback" mode;
# a failing stub exercises the native-table fallback.
write_exec(os.path.join(fbin, "asegstats2table"), "#!/usr/bin/env bash\necho 'stub: not implemented' >&2\nexit 1\n")
write_exec(os.path.join(fbin, "aparcstats2table"), "#!/usr/bin/env bash\nexit 1\n")

# ---------- synthetic DICOM session ----------
import numpy as np  # noqa: E402
import pydicom  # noqa: E402
from pydicom.dataset import FileDataset, FileMetaDataset  # noqa: E402
from pydicom.uid import ExplicitVRLittleEndian, generate_uid  # noqa: E402

dcm_root = os.path.join(OUT, "dicom")
study_uid = generate_uid()


def series(desc, number, nslices, size):
    sdir = os.path.join(dcm_root, "%02d_%s" % (number, desc))
    os.makedirs(sdir, exist_ok=True)
    s_uid = generate_uid()
    for z in range(nslices):
        meta = FileMetaDataset()
        meta.MediaStorageSOPClassUID = "1.2.840.10008.5.1.4.1.1.4"
        meta.MediaStorageSOPInstanceUID = generate_uid()
        meta.TransferSyntaxUID = ExplicitVRLittleEndian
        ds = FileDataset(None, {}, file_meta=meta, preamble=b"\0" * 128)
        ds.SOPClassUID = meta.MediaStorageSOPClassUID
        ds.SOPInstanceUID = meta.MediaStorageSOPInstanceUID
        ds.Modality = "MR"
        ds.Manufacturer = "SIEMENS"
        ds.PatientName = "Test^Patient"
        ds.PatientID = "TEST001"
        ds.PatientAge = "066Y"
        ds.PatientSex = "M"
        ds.PatientBirthDate = "19600101"
        ds.StudyDate = ds.SeriesDate = ds.AcquisitionDate = "20260115"
        ds.StudyInstanceUID = study_uid
        ds.SeriesInstanceUID = s_uid
        ds.SeriesNumber = number
        ds.InstanceNumber = z + 1
        ds.SeriesDescription = ds.ProtocolName = desc
        ds.ImageType = ["ORIGINAL", "PRIMARY", "M", "ND"]
        ds.MagneticFieldStrength = 3
        ds.SliceThickness = 1.0
        ds.PixelSpacing = [1.0, 1.0]
        ds.ImageOrientationPatient = [1, 0, 0, 0, 1, 0]
        ds.ImagePositionPatient = [0.0, 0.0, float(z)]
        ds.SliceLocation = float(z)
        ds.RepetitionTime = 2300
        ds.EchoTime = 2.98
        ds.Rows = ds.Columns = size
        ds.SamplesPerPixel = 1
        ds.PhotometricInterpretation = "MONOCHROME2"
        ds.BitsAllocated = 16
        ds.BitsStored = 12
        ds.HighBit = 11
        ds.PixelRepresentation = 0
        ds.PixelData = (np.random.RandomState(z).randint(0, 4000, (size, size)).astype("uint16")).tobytes()
        ds.save_as(os.path.join(sdir, "IM%04d.dcm" % (z + 1)), write_like_original=False)


series("localizer", 1, 3, 32)
series("t1_mprage_sag", 2, 24, 64)
series("t1_mprage_gd", 3, 30, 64)   # post-contrast: bigger, must NOT be chosen
print("fixtures in", OUT)
