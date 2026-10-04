#!/usr/bin/env python3
"""Visual quality control of a FreeSurfer subject with MNE-Python.

Writes into <out_dir>:
  mne_slices_coronal.png / _axial.png / _sagittal.png
      white (gray/white boundary) and pial surfaces drawn over the T1 slices
      (mne.viz.plot_bem) - the standard check that recon-all placed the
      surfaces correctly. If BEM surfaces exist (inner/outer skull, scalp,
      e.g. from `--bem`), they are drawn too.
  mne_aparc_3d.png
      3D pial surface of both hemispheres coloured by the Desikan-Killiany
      (aparc) parcellation, lateral + medial views (mne.viz.Brain) - the same
      regions the percentile report is computed on.
  mne_report.html
      an MNE Report bundling the figures (open in any browser).
  mne_qc.json
      what was produced, and with which MNE version.

3D rendering needs a display; on servers run it under xvfb-run (the pipeline
does this automatically). With --no-3d only the 2D slices are made.

Usage:
  mne_visualize.py --subjects-dir DIR --subject ID --out-dir DIR [--no-3d] [--bem]
"""
import argparse
import json
import os
import sys
import traceback


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--subjects-dir", required=True)
    ap.add_argument("--subject", required=True)
    ap.add_argument("--out-dir", required=True)
    ap.add_argument("--no-3d", action="store_true", help="skip the 3D parcellation render")
    ap.add_argument("--bem", action="store_true",
                    help="first build BEM surfaces with mne.bem.make_watershed_bem (needs FreeSurfer)")
    args = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import mne
    import nibabel as nib
    import numpy as np

    mne.set_log_level("WARNING")
    sd, subj, out = os.path.abspath(args.subjects_dir), args.subject, os.path.abspath(args.out_dir)
    sdir = os.path.join(sd, subj)
    os.makedirs(out, exist_ok=True)
    for need in ("mri/T1.mgz", "surf/lh.white", "surf/lh.pial", "surf/rh.white", "surf/rh.pial"):
        if not os.path.exists(os.path.join(sdir, need)):
            sys.exit("ERROR: %s is missing - has recon-all finished for %s?" % (need, subj))
    # plot_bem needs the bem/ folder recon-all normally creates
    os.makedirs(os.path.join(sdir, "bem"), exist_ok=True)

    produced, problems = [], []

    if args.bem:
        try:
            mne.bem.make_watershed_bem(subj, subjects_dir=sd, overwrite=True, verbose="WARNING")
            produced.append("bem/watershed")
        except Exception as exc:  # noqa: BLE001 - BEM is optional
            problems.append("watershed BEM failed: %s" % exc)

    # ---- 2D: surfaces over T1 slices -------------------------------------
    t1 = nib.load(os.path.join(sdir, "mri", "T1.mgz"))
    data = t1.get_fdata(dtype="float32")
    brain_mask = data > (0.4 * data.max())
    figs = {}
    # conformed volume axes -> MNE orientation: coronal=axis 2? (MNE handles it);
    # choose slices inside the brain along each MNE orientation's axis.
    axis_for = {"coronal": 2, "axial": 1, "sagittal": 0}
    for orient, ax in axis_for.items():
        other = tuple(a for a in range(3) if a != ax)
        idx = np.flatnonzero(brain_mask.any(axis=other))
        lo, hi = (int(idx[0]), int(idx[-1])) if idx.size else (60, 196)
        slices = [int(lo + (hi - lo) * f) for f in (0.25, 0.42, 0.58, 0.75)]
        try:
            fig = mne.viz.plot_bem(subject=subj, subjects_dir=sd, orientation=orient,
                                   slices=slices, brain_surfaces=["white", "pial"], show=False)
            fig.suptitle("%s - %s: white + pial surfaces" % (subj, orient), color="w")
            path = os.path.join(out, "mne_slices_%s.png" % orient)
            fig.savefig(path, dpi=110, facecolor="black")
            figs[orient] = fig
            produced.append(os.path.basename(path))
        except Exception as exc:  # noqa: BLE001
            problems.append("%s slices: %s" % (orient, exc))

    # ---- 3D: parcellation on the pial surface ----------------------------
    brain_png = None
    if not args.no_3d:
        try:
            mne.viz.set_3d_backend("pyvistaqt")
            has_annot = all(os.path.exists(os.path.join(sdir, "label", h + ".aparc.annot")) for h in ("lh", "rh"))
            brain = mne.viz.Brain(subj, hemi="split", surf="pial", subjects_dir=sd,
                                  views=["lateral", "medial"], background="white",
                                  cortex="low_contrast", size=(1200, 900), show=False)
            if has_annot:
                brain.add_annotation("aparc", borders=False, alpha=0.9)
            else:
                problems.append("no aparc annotation; 3D view shows bare cortex")
            brain_png = os.path.join(out, "mne_aparc_3d.png")
            brain.save_image(brain_png)
            brain.close()
            produced.append(os.path.basename(brain_png))
        except Exception as exc:  # noqa: BLE001
            problems.append("3D render: %s" % exc)
            brain_png = None

    # ---- HTML report -------------------------------------------------------
    try:
        report = mne.Report(title="FreeSurfer visual QC - %s" % subj, subject=subj, subjects_dir=sd)
        for orient, fig in figs.items():
            report.add_figure(fig, title="Surfaces on T1 - %s" % orient, section="Surfaces")
        if brain_png:
            report.add_image(brain_png, title="Desikan-Killiany parcellation (aparc)", section="Parcellation")
        report.save(os.path.join(out, "mne_report.html"), overwrite=True, open_browser=False)
        produced.append("mne_report.html")
    except Exception as exc:  # noqa: BLE001
        problems.append("HTML report: %s" % exc)
    plt.close("all")

    with open(os.path.join(out, "mne_qc.json"), "w") as fh:
        json.dump({"subject": subj, "mne_version": mne.__version__, "produced": produced,
                   "problems": problems}, fh, indent=2)
    for p in problems:
        print("WARNING: " + p, file=sys.stderr)
    print("MNE %s visual QC -> %s: %s" % (mne.__version__, out, ", ".join(produced)))
    return 0 if any(p.startswith("mne_slices") for p in produced) else 1


if __name__ == "__main__":
    try:
        sys.exit(main())
    except SystemExit:
        raise
    except Exception:  # noqa: BLE001
        traceback.print_exc()
        sys.exit(1)
