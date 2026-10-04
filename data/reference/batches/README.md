# Reference cohorts (normal controls)

The percentile-for-age models are fitted on the control subjects in this folder.
Use **one subfolder per cohort**:

```
data/reference/batches/                 <- NEUROIMAGING_REFERENCE_DIR (setup.conf: REFERENCE_DIR)
├── ICBM/
│   ├── ICBM_demographics.csv           <- Subject, Age (Sex optional)   ** fill in the ages **
│   ├── lhaparc_ICBM.txt  rhaparc_ICBM.txt  segstats_ICBM.txt
├── PPMI/
│   ├── PPMI_T1_controls_1.5T_9_10_2020.csv   PPMI_T1_controls_3T_9_10_2020.csv
│   ├── batch_1/ batch_2/ batch_3/      <- folder_*/ ?haparc_*.txt, asegstats_vol_*.txt
│   └── batch1_hippo.txt  batch1_brainstem.txt  ...
└── ADNI/
    ├── ADNI_T1_controls_1.5T_9_11_2020.csv   ADNI_T1_controls_3T_9_11_2020.csv
    ├── batch_4/
    └── batch3_hippo.txt  batch4_hippo.txt  ...
```

Subfolder names inside a cohort don't matter, because the folder is searched
recursively. What matters:

1. **Stats tables.** Each must be a FreeSurfer `*stats2table` output whose file
   name follows one of these patterns: `lhaparc_vol*.txt`, `rhaparc_thick*.txt`,
   `lhaparc_area*.txt`, `asegstats_vol*.txt`, `*_hippo.txt` /
   `hipposubfield_vol*.txt`, `*_brainstem.txt` / `brainstemstruct_vol*.txt`,
   `lhaparc_ICBM.txt` / `rhaparc_ICBM.txt` / `segstats_ICBM.txt`. The first
   column is the scan's subject ID.
2. **Demographics.** You need a CSV whose **file name starts with the cohort
   name** (`ICBM_…csv`, `PPMI_…csv`, `ADNI_…csv`) and which has **`Subject`** and
   **`Age`** columns (`Sex` is optional). The CSV exports from LONI IDA work as
   they are.
3. **Matching.** A scan gets an age when its subject ID contains the cohort name
   and the `Subject` value as a **whole token**:

   | Cohort | `Subject` in CSV | Matches scan ID |
   |---|---|---|
   | PPMI | `3053` | `PPMI_3053_MR_SAG_3D_T1` |
   | ADNI | `002_S_6007` | `ADNI_002_S_6007_MR_Accelerated…` |
   | ICBM | `MNI_0103` | `ICBM_MNI_0103_MRI_T1-FFE_br_…` |

**Scans with no age are left out of the models.** Check what is being used with:

```bash
neuroimaging reference              # per-cohort counts
neuroimaging reference --unmatched  # list the scans that are left out
neuroimaging reference --rebuild    # refit the models after adding data
```

The same counts appear in the app under **Reference Models**.

## ICBM: ages needed

The repository holds FreeSurfer tables for 91 ICBM controls (volumes only), but
**not their ages**. The original project read them from an
`all_controls_demographics.csv` that was never committed. Until the ages are
filled in, ICBM is not used. To include it:

1. Open `ICBM/ICBM_demographics.csv`. It already lists all 91 `MNI_xxxx` IDs.
2. Fill in `Age` (and `Sex`) from the ICBM metadata (LONI IDA), or replace the
   file with an IDA export whose `Subject` column has those `MNI_xxxx` IDs.
3. Run `neuroimaging reference --rebuild`.

## Adding or reprocessing a cohort

You can put existing tables in a new `<COHORT>/` folder with a `<COHORT>_*.csv`.
To reprocess raw MRI with the same FreeSurfer 8 used for patients (recommended),
run:

```bash
neuroimaging cohort --cohort PPMI --dicom-root /data/PPMI_dicom --demographics PPMI_controls.csv
```

`--dicom-root` must hold one subfolder per subject. This writes to
`data/reference/batches_fs8/PPMI/`. Repeat for ICBM and ADNI, then set
`REFERENCE_DIR=data/reference/batches_fs8` in `setup.conf` (or set
`NEUROIMAGING_REFERENCE_DIR`), and run `neuroimaging reference --rebuild`.
