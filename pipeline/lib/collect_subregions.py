#!/usr/bin/env python3
"""Collect hippocampal-subfield and brainstem volumes into the per-subject
tables the app reads (hipposubfield_vol.txt / brainstemstruct_vol.txt).

FreeSurfer >= 7 deprecated quantifyHippocampalSubfields.sh and
quantifyBrainstemStructures.sh (used by the legacy recon_report.sh); this
script reads the files written by segmentHA_T1.sh / segmentBS.sh directly:

    $SUBJECTS_DIR/<subj>/mri/lh.hippoSfVolumes-T1.v<NN>.txt
    $SUBJECTS_DIR/<subj>/mri/rh.hippoSfVolumes-T1.v<NN>.txt
    $SUBJECTS_DIR/<subj>/mri/brainstemSsVolumes.v<NN>.txt

and writes the same space-separated "Subject <col> <col> ..." layout as the
old quantify scripts, with left_/right_ prefixes on hippocampal columns.
Head/body sub-divisions reported by FS >= 7 are kept as-is here; the R app
harmonises them to the FreeSurfer 6 names used by the reference cohort.

Usage:
    collect_subregions.py <subjects_dir> <subject> <output_dir>
"""
import glob
import os
import re
import sys


def newest(pattern):
    hits = glob.glob(pattern)
    if not hits:
        return None

    def ver(p):
        m = re.search(r"\.v(\d+)\.txt$", p)
        return int(m.group(1)) if m else -1

    return max(hits, key=ver)


def read_volumes(path):
    vals = []
    with open(path) as fh:
        for line in fh:
            parts = line.split()
            if len(parts) >= 2 and not parts[0].startswith("#"):
                vals.append((parts[0], parts[-1]))
    return vals


def write_table(path, subject, pairs):
    with open(path, "w") as fh:
        fh.write(" ".join(["Subject"] + [k for k, _ in pairs]) + "\n")
        fh.write(" ".join([subject] + [v for _, v in pairs]) + "\n")


def main(argv):
    if len(argv) != 4:
        print(__doc__, file=sys.stderr)
        return 2
    subjects_dir, subject, out_dir = argv[1:]
    mri = os.path.join(subjects_dir, subject, "mri")
    os.makedirs(out_dir, exist_ok=True)
    status = 0

    lh = newest(os.path.join(mri, "lh.hippoSfVolumes-T1.v*.txt"))
    rh = newest(os.path.join(mri, "rh.hippoSfVolumes-T1.v*.txt"))
    if lh and rh:
        pairs = [("left_" + k, v) for k, v in read_volumes(lh)] + \
                [("right_" + k, v) for k, v in read_volumes(rh)]
        write_table(os.path.join(out_dir, "hipposubfield_vol.txt"), subject, pairs)
        print("hippocampal subfields: %s, %s" % (os.path.basename(lh), os.path.basename(rh)))
    else:
        print("WARNING: no hippocampal subfield volumes found in %s" % mri, file=sys.stderr)
        status = 1

    bs = newest(os.path.join(mri, "brainstemSsVolumes.v*.txt"))
    if bs:
        write_table(os.path.join(out_dir, "brainstemstruct_vol.txt"), subject, read_volumes(bs))
        print("brainstem structures: %s" % os.path.basename(bs))
    else:
        print("WARNING: no brainstem volumes found in %s" % mri, file=sys.stderr)
        status = 1
    return status


if __name__ == "__main__":
    sys.exit(main(sys.argv))
