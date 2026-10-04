#!/usr/bin/env python3
"""Write a synthetic FreeSurfer-like anatomy into <subject_dir> so the MNE
visualisation step can be tested without a real recon-all:

  mri/T1.mgz, mri/brain.mgz, mri/aparc+aseg.mgz
  surf/{lh,rh}.{white,pial,inflated,curv,sphere}
  label/{lh,rh}.aparc.annot

Geometry: each hemisphere is a pair of nested ellipsoids (white inside pial)
in FreeSurfer surface RAS, inside a bright "head" in a 256^3 1 mm volume.
Needs nibabel + numpy (the project's MNE environment has both).

Usage: make_fake_anatomy.py <subject_dir>
"""
import os
import sys

import nibabel as nib
import numpy as np
from nibabel.freesurfer import io as fsio

APARC = ["unknown", "bankssts", "caudalanteriorcingulate", "caudalmiddlefrontal", "cuneus",
         "entorhinal", "fusiform", "inferiorparietal", "inferiortemporal", "lateraloccipital",
         "lateralorbitofrontal", "lingual", "medialorbitofrontal", "middletemporal",
         "parahippocampal", "precentral", "postcentral", "precuneus", "superiorfrontal",
         "superiorparietal", "superiortemporal", "supramarginal", "insula"]


def icosphere(subdiv=4):
    t = (1 + 5 ** 0.5) / 2
    v = [(-1, t, 0), (1, t, 0), (-1, -t, 0), (1, -t, 0), (0, -1, t), (0, 1, t), (0, -1, -t), (0, 1, -t),
         (t, 0, -1), (t, 0, 1), (-t, 0, -1), (-t, 0, 1)]
    f = [(0, 11, 5), (0, 5, 1), (0, 1, 7), (0, 7, 10), (0, 10, 11), (1, 5, 9), (5, 11, 4), (11, 10, 2),
         (10, 7, 6), (7, 1, 8), (3, 9, 4), (3, 4, 2), (3, 2, 6), (3, 6, 8), (3, 8, 9), (4, 9, 5),
         (2, 4, 11), (6, 2, 10), (8, 6, 7), (9, 8, 1)]
    verts = [np.array(p, float) / np.linalg.norm(p) for p in v]
    faces = f
    for _ in range(subdiv):
        cache, new_faces = {}, []

        def mid(a, b):
            key = (min(a, b), max(a, b))
            if key not in cache:
                m = verts[a] + verts[b]
                verts.append(m / np.linalg.norm(m))
                cache[key] = len(verts) - 1
            return cache[key]
        for a, b, c in faces:
            ab, bc, ca = mid(a, b), mid(b, c), mid(c, a)
            new_faces += [(a, ab, ca), (b, bc, ab), (c, ca, bc), (ab, bc, ca)]
        faces = new_faces
    return np.array(verts), np.array(faces, dtype=np.int32)


def main(subject_dir):
    for d in ("mri", "surf", "label"):
        os.makedirs(os.path.join(subject_dir, d), exist_ok=True)

    # --- volumes: conformed 256^3, 1 mm, FreeSurfer "conformed" orientation
    affine = np.array([[-1, 0, 0, 128], [0, 0, 1, -128], [0, -1, 0, 128], [0, 0, 0, 1]], float)
    # conformed axes: x_ras = 128 - i, y_ras = k - 128, z_ras = 128 - j
    i, j, k = np.ogrid[0:256, 0:256, 0:256]
    x, y, z = (128.0 - i), (k - 128.0), (128.0 - j)
    head = (x / 78) ** 2 + (y / 98) ** 2 + (z / 82) ** 2 <= 1
    brain = (np.abs(x) / 62) ** 2 + (y / 82) ** 2 + (z / 66) ** 2 <= 1
    t1 = np.where(head, 60, 0) + np.where(brain, 50, 0)
    t1 = (t1 + np.random.RandomState(0).normal(0, 3, t1.shape)).clip(0, 255).astype(np.uint8)
    x = np.broadcast_to(x, t1.shape)
    nib.save(nib.MGHImage(t1, affine), os.path.join(subject_dir, "mri", "T1.mgz"))
    nib.save(nib.MGHImage(np.where(brain, t1, 0).astype(np.uint8), affine),
             os.path.join(subject_dir, "mri", "brain.mgz"))
    aseg = np.where(brain, np.where(x < 0, 3, 42), 0).astype(np.int32)
    nib.save(nib.MGHImage(aseg, affine), os.path.join(subject_dir, "mri", "aparc+aseg.mgz"))

    # --- surfaces: nested ellipsoids per hemisphere
    v, f = icosphere(5)
    ctab = np.array([[25 + (i * 53) % 230, 25 + (i * 97) % 230, 25 + (i * 31) % 230, 0, 0]
                     for i in range(len(APARC))], dtype=np.int32)
    ctab[:, 4] = ctab[:, 0] + ctab[:, 1] * 256 + ctab[:, 2] * 65536
    for hemi, sign in (("lh", -1), ("rh", 1)):
        center = np.array([sign * 32, -5, 5])
        white = v * np.array([26, 72, 54]) + center
        pial = v * np.array([30, 78, 60]) + center
        # gentle folding so curvature isn't flat
        bump = 2.0 * np.sin(6 * v[:, 1]) * np.cos(5 * v[:, 2])
        white += v * bump[:, None]
        pial += v * bump[:, None]
        hv = (v[:, 0] * sign).copy()  # mirror faces for the right hemisphere winding
        faces = f if sign > 0 else f[:, ::-1]
        meta = {"head": np.array([20], dtype=np.int32), "valid": "1  # volume info valid",
                "filename": "vol.nii", "volume": np.array([256, 256, 256]),
                "voxelsize": np.array([1.0, 1.0, 1.0]), "xras": np.array([-1.0, 0.0, 0.0]),
                "yras": np.array([0.0, 0.0, -1.0]), "zras": np.array([0.0, 1.0, 0.0]),
                "cras": np.array([0.0, 0.0, 0.0])}
        fsio.write_geometry(os.path.join(subject_dir, "surf", hemi + ".white"), white, faces, volume_info=meta)
        fsio.write_geometry(os.path.join(subject_dir, "surf", hemi + ".pial"), pial, faces, volume_info=meta)
        fsio.write_geometry(os.path.join(subject_dir, "surf", hemi + ".inflated"),
                            v * 60 + center * 1.6, faces, volume_info=meta)
        fsio.write_geometry(os.path.join(subject_dir, "surf", hemi + ".sphere"), v * 100, faces, volume_info=meta)
        fsio.write_morph_data(os.path.join(subject_dir, "surf", hemi + ".curv"), bump / 4 + 0 * hv)
        # parcellation: bin vertices by angle into the aparc regions
        ang = np.arctan2(v[:, 2], v[:, 1])
        lab = 1 + (((ang + np.pi) / (2 * np.pi)) * (len(APARC) - 1)).astype(int) % (len(APARC) - 1)
        fsio.write_annot(os.path.join(subject_dir, "label", hemi + ".aparc.annot"), lab, ctab, APARC,
                         fill_ctab=False)
    print("synthetic anatomy written to", subject_dir)


if __name__ == "__main__":
    main(sys.argv[1])
