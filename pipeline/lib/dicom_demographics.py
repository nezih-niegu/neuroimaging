#!/usr/bin/env python3
"""Extract patient age (years) and sex from a DICOM series.

Replaces the legacy `dctable ... -k PatientAge | cut | bc` one-liner, which
depended on a tool that is not packaged for Ubuntu 24.04 and broke on ages
not expressed in years.

Order of preference:
  1. pydicom              (apt: python3-pydicom)
  2. dcmdump from DCMTK    (apt: dcmtk)
  3. mri_probedicom        (ships with FreeSurfer)

Age is taken from PatientAge (0010,1010) - e.g. "066Y", "018M", "010W" -
and, if absent, computed from PatientBirthDate and StudyDate/AcquisitionDate.

Usage:
    dicom_demographics.py <dicom_dir_or_file>     -> prints JSON
    dicom_demographics.py <dir> --field age       -> prints just the value
"""
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import date

TAGS = {
    "PatientAge": (0x0010, 0x1010),
    "PatientSex": (0x0010, 0x0040),
    "PatientBirthDate": (0x0010, 0x0030),
    "StudyDate": (0x0008, 0x0020),
    "AcquisitionDate": (0x0008, 0x0022),
}


def is_dicom(path):
    try:
        with open(path, "rb") as fh:
            fh.seek(128)
            if fh.read(4) == b"DICM":
                return True
    except OSError:
        return False
    # Some old scanners write DICOM without the preamble; accept typical names
    name = os.path.basename(path)
    return bool(re.fullmatch(r"(I\d{7}|\d{8}|.*\.dcm|.*\.IMA)", name, re.I))


def find_first_dicom(root):
    if os.path.isfile(root):
        return root
    for dirpath, _, files in os.walk(root):
        for f in sorted(files):
            p = os.path.join(dirpath, f)
            if is_dicom(p):
                return p
    return None


def read_with_pydicom(path):
    import pydicom  # noqa: WPS433

    ds = pydicom.dcmread(path, stop_before_pixels=True, force=True)
    return {k: str(getattr(ds, k, "") or "").strip() for k in TAGS}


def read_with_dcmdump(path):
    exe = shutil.which("dcmdump")
    if not exe:
        raise RuntimeError("dcmdump not found")
    out = {}
    for key, (g, e) in TAGS.items():
        res = subprocess.run([exe, "-q", "+P", "%04x,%04x" % (g, e), path],
                             capture_output=True, text=True, check=False)
        m = re.search(r"\[(.*?)\]", res.stdout)
        out[key] = m.group(1).strip() if m else ""
    return out


def read_with_mri_probedicom(path):
    exe = shutil.which("mri_probedicom")
    if not exe:
        raise RuntimeError("mri_probedicom not found")
    out = {}
    for key, (g, e) in TAGS.items():
        res = subprocess.run([exe, "--i", path, "--t", "%04x" % g, "%04x" % e],
                             capture_output=True, text=True, check=False)
        out[key] = res.stdout.strip() if res.returncode == 0 else ""
    return out


def parse_dicom_date(s):
    s = re.sub(r"\D", "", s or "")
    if len(s) != 8:
        return None
    try:
        return date(int(s[:4]), int(s[4:6]), int(s[6:8]))
    except ValueError:
        return None


def age_years(tags):
    raw = (tags.get("PatientAge") or "").upper()
    m = re.fullmatch(r"0*(\d+)\s*([YMWD]?)", raw)
    if m and int(m.group(1)) > 0:
        n, unit = int(m.group(1)), m.group(2) or "Y"
        return round({"Y": n, "M": n / 12, "W": n / 52.1775, "D": n / 365.25}[unit], 2)
    born = parse_dicom_date(tags.get("PatientBirthDate"))
    scan = parse_dicom_date(tags.get("StudyDate")) or parse_dicom_date(tags.get("AcquisitionDate"))
    if born and scan and scan > born:
        return round((scan - born).days / 365.25, 2)
    return None


def main(argv):
    if len(argv) < 2:
        print(__doc__, file=sys.stderr)
        return 2
    field = None
    if "--field" in argv:
        field = argv[argv.index("--field") + 1]
    path = find_first_dicom(argv[1])
    if not path:
        print(json.dumps({"error": "no DICOM file found"}))
        return 1

    tags, source = None, None
    for reader in (read_with_pydicom, read_with_dcmdump, read_with_mri_probedicom):
        try:
            tags = reader(path)
            source = reader.__name__.replace("read_with_", "")
            break
        except Exception:  # noqa: BLE001 - try the next backend
            continue
    if tags is None:
        print(json.dumps({"error": "install python3-pydicom or dcmtk to read DICOM headers"}))
        return 1

    sex = (tags.get("PatientSex") or "").upper()[:1]
    result = {
        "age": age_years(tags),
        "sex": sex if sex in ("M", "F") else None,
        "dicom_file": path,
        "reader": source,
    }
    if field:
        val = result.get(field)
        print("" if val is None else val)
    else:
        print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
