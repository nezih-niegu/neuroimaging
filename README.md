# Neuroimaging Normative Reference

One project that takes a patient's MRI from **raw DICOMs to a clinical
percentile-for-age report**:

```
DICOM ──dcm2niix──► T1 ──FreeSurfer 8 (recon-all, segmentHA_T1, segmentBS)──► stats
      ──► normative models (ICBM / PPMI / ADNI controls) ──► patient DB + PDF (CDISC SDTM/ADaM)
```

It has four parts, which all share the same code and data:

- the **FreeSurfer pipeline** (`pipeline/`), which runs on **Ubuntu 24.04** with
  the official FreeSurfer 8.x package;
- **MNE-Python visualisation** of every FreeSurfer result: cortical surfaces drawn
  on the MRI, a 3D view of the brain regions, and an interactive HTML report;
- an **R Shiny app**, where you can start FreeSurfer runs, load processed subjects,
  review reports and keep the patient database;
- a **plumber REST API** that exposes the same functions to other systems.

This replaces the old split, where FreeSurfer processing lived in a separate bash +
Python script (`legacy/recon_report.sh`) and the app only accepted its output
files. **That legacy script no longer works on current FreeSurfer:** it calls
`recon-all … -hippocampal-subfields-T1`, which FreeSurfer 7 and later reject
with an error, and the `quantify*.sh` tools it used are deprecated. It is kept
in `legacy/` only as a record of the original method.

---

## Setup: one command (Ubuntu 24.04)

```bash
sudo ./setup.sh --license ~/license.txt
```

This single command installs and configures the whole project:

1. **The app:** R and every R package, dcm2niix and DICOM tools, all from Ubuntu's own archive.
2. **FreeSurfer 8.2.0:** the official `freesurfer_ubuntu24-8.2.0_amd64.deb`, plus your license.
3. **MATLAB runtime R2019b:** needed for the hippocampal-subfield and brainstem steps.
4. **MNE-Python:** MNE, PyVista and Xvfb, installed in `/opt/neuroimaging/venv`, so the
   3D views also render on servers with no screen.
5. **Configuration:** `/etc/neuroimaging/neuroimaging.env`, a system-wide `neuroimaging`
   command, data folders owned by you, and the reference models built in advance.
6. **Optional systemd service** (`--service`): the app and API start at boot.
7. **A self-test** of the whole pipeline, followed by an environment report.

It takes a while the first time, because the FreeSurfer package is several GB.
Running it again is safe: anything already installed is kept and the rest is
updated.

You can get a FreeSurfer license for free at
<https://surfer.nmr.mgh.harvard.edu/registration.html>. If you leave out
`--license`, setup looks for `./freesurfer_license/license.txt` and then
`~/license.txt`.

| Option | |
|---|---|
| `--license FILE` | FreeSurfer license |
| `--fs-deb FILE` | Use a FreeSurfer `.deb` you already downloaded (no download) |
| `--service` | Install and start the systemd service |
| `--user NAME` | Account that owns the data and runs the service (default: the user who ran sudo) |
| `--no-freesurfer` / `--no-mcr` / `--no-mne` | Leave a component out (for example, a viewing-only server) |
| `--config FILE` | Settings file (default: `./setup.conf` if it exists) |
| `--skip-tests` | Don't run the self-test |

To keep your settings, copy `setup.conf.example` to `setup.conf` and edit it.
This covers FreeSurfer version, MNE location, data folders, ports, the service
and its user. After that, `sudo ./setup.sh` is all you need to run.

Once setup finishes, open a new terminal and run:

```bash
neuroimaging check                                              # everything [ok]?
neuroimaging process --subject sub-001 --dicom /data/dicom/sub-001 --report
neuroimaging serve                                              # app :3838, API :8000
```

`bin/neuroimaging` is the single entry point for every task:

| Command | What it does |
|---|---|
| `sudo bin/neuroimaging setup …` | Same as `./setup.sh` |
| `bin/neuroimaging check` | Checks FreeSurfer version, license, MATLAB runtime, MNE, dcm2niix, R |
| `bin/neuroimaging process …` | Runs the FreeSurfer pipeline for one subject (see below) |
| `bin/neuroimaging visualize --subject ID` | Makes (or remakes) the MNE figures for a processed subject |
| `bin/neuroimaging reference [--unmatched] [--rebuild]` | Shows which ICBM/PPMI/ADNI subjects the models use; refits the models |
| `bin/neuroimaging cohort --cohort NAME --dicom-root DIR --demographics CSV` | Runs FreeSurfer on a whole control cohort and files the results as reference data |
| `bin/neuroimaging ingest --subject-dir DIR --age N` | Report + DB + PDF for an already-processed subject |
| `bin/neuroimaging serve` | Starts the REST API and the Shiny app together |
| `bin/neuroimaging api` / `app` | Starts just one of them |
| `bin/neuroimaging test` | Runs the end-to-end pipeline test (no FreeSurfer needed) |

---

## Quick start: Docker

```bash
# App only (amd64 and arm64 / Apple Silicon)
docker compose up --build

# App + FreeSurfer 8.2.0 (amd64; adds several GB to the image)
mkdir -p freesurfer_license && cp ~/license.txt freesurfer_license/
WITH_FREESURFER=1 docker compose up --build
```

- Shiny app: <http://localhost:3838>
- API docs (Swagger): <http://localhost:8000/__docs__/>

The image is `ubuntu:24.04` and is set up by the same `install/install_ubuntu24.sh`
that `setup.sh` uses, so it includes MNE-Python. Add `WITH_MNE=0` to leave MNE out. Patients, FreeSurfer subjects, uploads and job logs are kept
in the `neuroimaging_data` volume (`/app/data`). To process DICOMs that already
sit on the host, mount them under `/app/data/incoming/` (there is a commented
example in `docker-compose.yml`).

---

## Reference cohorts: where ICBM, PPMI and ADNI go

```
data/reference/batches/          (or REFERENCE_DIR in setup.conf)
├── ICBM/   ICBM_demographics.csv + lhaparc_ICBM.txt, rhaparc_ICBM.txt, segstats_ICBM.txt
├── PPMI/   PPMI_*.csv            + batch_1/ batch_2/ batch_3/ + batch*_hippo/brainstem.txt
└── ADNI/   ADNI_*.csv            + batch_4/                    + batch*_hippo/brainstem.txt
```

Each cohort needs its FreeSurfer stats tables and a `<COHORT>_*.csv` with
`Subject` and `Age` columns. Only scans that can be given an age are used.
`neuroimaging reference` shows the counts per cohort, and the app shows the same
under **Reference Models**. Full details, including how to reprocess a cohort with
FreeSurfer 8 (`neuroimaging cohort …`), are in
[`data/reference/batches/README.md`](data/reference/batches/README.md).

> **ICBM is currently unused.** The repo has ICBM's FreeSurfer tables but not the
> subjects' ages. The original project read them from an `all_controls_demographics.csv`
> that was never committed. Fill in `ICBM/ICBM_demographics.csv` (all 91 IDs are
> already listed), then run `neuroimaging reference --rebuild`.
>
> **Fixed:** the app's subject-to-age matching used plain substring search across
> all cohorts. This gave 19 ICBM scans the age of an unrelated PPMI subject, whose
> short numeric ID happened to appear inside the ICBM scan ID. Matching now stays
> within the scan's own cohort and compares whole tokens only. If you saved
> patients with an earlier build, rebuild the models and re-save those patients.

---

## The FreeSurfer pipeline

`pipeline/neuroimaging-pipeline.sh` (or `bin/neuroimaging process`) processes one subject:

| Step | Ubuntu 24.04 / FreeSurfer 8 implementation | Legacy `recon_report.sh` |
|---|---|---|
| 1. Age / sex | Read from the DICOM header (`PatientAge`, or computed from birth date and study date) via pydicom → dcmdump → mri_probedicom; override with `--age/--sex` | `dctable` (not packaged for Ubuntu 24.04); years only |
| 2. DICOM → NIfTI | `dcm2niix`, then pick the largest T1 series, **excluding** contrast-enhanced, localizer and scanner-derived series | Same idea (largest T1, excluding gadolinium series) |
| 3. Reconstruction | `recon-all -all -threads N`; skipped if the subject is already complete, resumed if it was partly done | `recon-all -all … -hippocampal-subfields-T1 -brainstem-structures` (**fails on FreeSurfer ≥ 7**) |
| 4. Subregions | `segmentHA_T1.sh` + `segmentBS.sh` (needs MATLAB runtime R2019b); skipped with a warning if the runtime is missing | Built into recon-all (removed upstream) |
| 5. Tables | `asegstats2table` / `aparcstats2table`, and hippocampal/brainstem tables read from `mri/*.v22.txt`, `*.v13.txt`; if those tools fail, the app's own reader writes the tables instead | Same tools + deprecated `quantify*.sh` |
| 6. Visualisation | **MNE-Python**: white and pial surfaces on T1 slices, a 3D view of the brain regions, and an HTML report, in `qc/` (see below) | – |
| 7. Report | `--report`: R models → patient DB + `<ID>_report.pdf`, including the MNE figures (`--api URL` sends it through a running API) | Python + pdfkit, with hard-coded `/home/neurocogn/...` paths |

```
pipeline/neuroimaging-pipeline.sh --subject ID (--dicom DIR | --t1 FILE | --existing)
    [--age Y] [--sex M|F] [--subjects-dir DIR] [--output-dir DIR]
    [--threads N] [--no-subregions] [--force] [--report] [--api URL]
    [--no-mne] [--no-3d] [--bem]
```

Outputs go to `data/processed/<ID>/`: the legacy-format `*.txt` tables (these can
also be uploaded in the app), `pipeline_run.json` (FreeSurfer version, OS, T1 used,
age and sex) and the PDF. The FreeSurfer subject itself goes to `SUBJECTS_DIR`
(default `data/freesurfer_subjects/`).

> **Resources.** recon-all takes several hours per subject. FreeSurfer's 8.x
> release notes say multi-threaded runs can use a lot of RAM, so if a machine
> runs out of memory, lower `--threads`.

### Brain visualisation with MNE-Python

[MNE-Python](https://mne.tools) reads the FreeSurfer output. It doesn't replace
FreeSurfer: `recon-all` still has to run first. Step 6 (`pipeline/lib/mne_visualize.py`)
writes these files to `data/processed/<ID>/qc/`:

| File | What it shows |
|---|---|
| `mne_slices_{coronal,axial,sagittal}.png` | The **white** and **pial** surfaces drawn on T1 slices (`mne.viz.plot_bem`). This is the standard check that recon-all put the cortical surfaces in the right place. Check it before trusting the numbers. |
| `mne_aparc_3d.png` | The pial surface of both hemispheres, lateral and medial views, coloured by the **Desikan-Killiany (aparc) parcellation** (`mne.viz.Brain`). These are the regions the percentile tables report. |
| `mne_report.html` | An `mne.Report` with all the figures in one file you can open in any browser |

The figures also appear:

- in the **clinical PDF**, on pages after the title page;
- in the **app**, under FreeSurfer → *Brain visualisation*, where you can also remake
  them and download the HTML report;
- in the **API**, at `GET /freesurfer/subjects/{id}/qc/{file}`.

On a server without a screen, the 3D view is rendered through Xvfb automatically.
`--bem` also builds MNE's watershed BEM surfaces (skull and scalp), which are useful
if the same subject will be used for MEG/EEG source modelling, and draws them on
the slices. Each run takes about 5–60 seconds per subject.

### Running it from the app or the API

- **Shiny → FreeSurfer tab**: shows whether FreeSurfer is ready, lets you start a
  run from an uploaded DICOM `.zip` or a folder on the server, and lists runs with
  their live log. When a run succeeds, the patient appears under *Patient Database*.
  *Load an already-processed subject* reads any subject in `SUBJECTS_DIR` directly
  (no FreeSurfer needed) and opens it in *New Patient*.
- **API**: `POST /pipeline/jobs` starts a run and `GET /pipeline/jobs/{id}` reports
  its progress (see the table below). For safety, server-side input paths must be
  inside `data/incoming/`, `SUBJECTS_DIR`, or folders listed in
  `NEUROIMAGING_INPUT_ROOTS`.

Each run is a folder in `data/jobs/<job_id>/` (request, live log, exit code), so
runs keep going if the app restarts.

### FreeSurfer version compatibility (important)

The bundled control cohort was processed in 2020 with **FreeSurfer 6**. New
patients are processed with **FreeSurfer 8**. Two kinds of naming change
would otherwise make regions silently drop out of the report. The app maps
them back to the reference naming (`R/freesurfer_native.R`):

- `Left-/Right-Thalamus` (FS ≥ 7) → `Left-/Right-Thalamus-Proper` (FS 6);
- the FS ≥ 7 hippocampal head/body parts (e.g. `CA1-head` + `CA1-body`) are
  summed back into the FS 6 subfield (`CA1`). FS ≥ 7-only totals are dropped.

This keeps every region comparable by name. **It cannot remove the systematic
differences between FreeSurfer versions**, though. Volumes and thicknesses from
FS 6 and FS 8 are known to differ slightly, and the hippocampal atlas changed
between versions. For clinical use, reprocess the control cohort with the same
FreeSurfer version used for patients: run the pipeline on each control without
`--report`, put the resulting tables under `data/reference/batches/`, and click
**Reference Models → (Re)build**.

---

## What each piece does

| File | Role |
|------|------|
| `pipeline/neuroimaging-pipeline.sh` | FreeSurfer pipeline for one subject (Ubuntu 24.04, FS 7/8) |
| `pipeline/check_environment.sh` | Checks whether FreeSurfer is ready (`--json` output is used by the app and API) |
| `pipeline/lib/freesurfer_env.sh` | Finds FreeSurfer, its version, license and MATLAB runtime |
| `pipeline/lib/dicom_demographics.py` | Reads age and sex from DICOM headers |
| `pipeline/lib/collect_subregions.py` | Builds hippocampal and brainstem tables (replaces `quantify*.sh`) |
| `pipeline/lib/mne_visualize.py` / `pipeline/visualize.sh` | MNE-Python figures: surfaces on T1, 3D parcellation, HTML report |
| `setup.sh` | One-command setup of the whole project |
| `install/install_ubuntu24.sh` | Component installer used by `setup.sh` and the Dockerfile (app / FreeSurfer / MATLAB runtime / MNE) |
| `bin/neuroimaging` | Single command-line entry point |
| `bin/ingest_subject.R` | Processed subject → report, DB and PDF (step 6 of the pipeline) |
| `bin/export_tables.R` | Writes legacy-format tables straight from a FreeSurfer subject folder |
| `R/freesurfer_native.R` | Reads `aseg.stats`, `?h.aparc.stats`, subfield volumes; maps FS 6/FS 8 names |
| `R/pipeline_jobs.R` | Background pipeline runs, environment status, DICOM zip staging |
| `R/parse_freesurfer.R` | Reads the `*stats2table` tables into tidy data, keyed by subject |
| `R/reference_data.R` | Joins the control-cohort batches to age and sex (cohort-aware, whole-token ID matching); coverage report |
| `pipeline/process_cohort.sh` | Runs a whole control cohort through FreeSurfer into `batches_fs8/<COHORT>/` |
| `R/regression.R` | `lm(value ~ age)` for each region and age group, with 95% prediction intervals |
| `R/report.R` | Percentile-for-age and out-of-range flags; scatter plots |
| `R/cdisc.R` | CDISC **SDTM** and **ADaM** datasets |
| `R/pdf_report.R` | Clinical PDF |
| `R/db.R` | SQLite patient database |
| `plumber.R` / `app.R` | REST API / Shiny frontend |
| `tests/` | End-to-end test with a stub FreeSurfer 8 and synthetic DICOMs |
| `legacy/` | Original scripts, kept for reference only (not used) |

---

## Using the app

1. **New scan:** go to **FreeSurfer**, enter an ID, upload the DICOM `.zip` and
   click *Start FreeSurfer run*. Age and sex are read from the DICOM header
   unless you enter them.
2. **Subject already processed with FreeSurfer:** go to **FreeSurfer**, use
   *Load an already-processed subject*, then review it in **New Patient**.
3. **Only have the stats tables:** go to **New Patient** and upload the `*.txt`
   files. A ready-made example is in [`examples/sample_subject/`](examples/sample_subject/).
4. In **New Patient**, click **Save to database**, then **Download clinical PDF**.

---

## REST API reference

Base URL: `http://localhost:8000` (Swagger UI at `/__docs__/`)

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Service health + loaded regions |
| `POST` | `/models/rebuild` | Rebuild the regression models from disk |
| `GET`  | `/patients` | List all patients |
| `POST` | `/patients` | Compute + store a new patient's report from stats values |
| `GET`  | `/patients/{id}` | One patient's demographics + report |
| `DELETE` | `/patients/{id}` | Delete a patient |
| `GET`  | `/patients/{id}/report.pdf` | Download the clinical PDF |
| `GET`  | `/patients/{id}/cdisc` | SDTM + ADaM datasets as JSON |
| `GET`  | `/freesurfer/status` | FreeSurfer version, license, MATLAB runtime, dcm2niix, readiness |
| `GET`  | `/freesurfer/subjects` | Processed subjects in `SUBJECTS_DIR` |
| `POST` | `/freesurfer/import` | `{subject, age, [patient_id, sex, …]}`: store a processed subject as a patient |
| `POST` | `/pipeline/jobs` | `{subject_id, dicom_dir \| t1_path \| existing, [age, sex, threads, subregions]}`: start a run (202) |
| `GET`  | `/pipeline/jobs` | List runs |
| `GET`  | `/pipeline/jobs/{job_id}` | Status (`running` / `succeeded` / `failed`), current step, log tail |
| `GET`  | `/freesurfer/subjects/{id}/qc` | List the subject's MNE visualisation files |
| `POST` | `/freesurfer/subjects/{id}/qc?three_d=true&bem=false` | Make (or remake) the MNE figures |
| `GET`  | `/freesurfer/subjects/{id}/qc/{file}` | Get one figure (`image/png`), the HTML report or the JSON summary |

```bash
# start a FreeSurfer run on DICOMs already on the server
curl -X POST localhost:8000/pipeline/jobs -H 'Content-Type: application/json' \
     -d '{"subject_id":"sub-001","dicom_dir":"/app/data/incoming/sub-001"}'
curl localhost:8000/pipeline/jobs/<job_id>
curl -o report.pdf localhost:8000/patients/sub-001/report.pdf
```

`POST /patients` still accepts raw stats values (keys `lh_vol, rh_vol, lh_thick,
rh_thick, lh_area, rh_area, seg_vol, hippo_vol, brainstem_vol`), for systems that
run FreeSurfer somewhere else.

---

## Configuration (environment variables)

| Variable | Default | Meaning |
|----------|---------|---------|
| `FREESURFER_HOME` | auto: newest `/usr/local/freesurfer/<ver>` | FreeSurfer install |
| `FS_LICENSE` | auto: `/usr/local/freesurfer/license.txt` | FreeSurfer license file |
| `NEUROIMAGING_SUBJECTS_DIR` | `$SUBJECTS_DIR` or `data/freesurfer_subjects` | FreeSurfer subjects |
| `NEUROIMAGING_INCOMING_DIR` | `data/incoming` | Where DICOM uploads are unpacked |
| `NEUROIMAGING_PROCESSED_DIR` | `data/processed` | Pipeline outputs (tables, PDF) |
| `NEUROIMAGING_JOBS_DIR` | `data/jobs` | Pipeline run logs and status |
| `NEUROIMAGING_MNE_PYTHON` | auto: `/opt/neuroimaging/venv/bin/python` | Python interpreter that has MNE |
| `NEUROIMAGING_INPUT_ROOTS` | *(none)* | Extra `:`-separated folders the API may read input from |
| `NEUROIMAGING_MAX_UPLOAD_MB` | `4096` | Maximum DICOM zip upload size in the app |
| `NEUROIMAGING_API_PORT` / `_APP_PORT` | `8000` / `3838` | Ports |
| `NEUROIMAGING_API_URL` | `http://127.0.0.1:8000` | Where the app reaches the API (falls back to in-process) |
| `NEUROIMAGING_REFERENCE_DIR` | `data/reference/batches` | Control-cohort batches |
| `NEUROIMAGING_MODELS_PATH` | `data/reference_models.rds` | Cached fitted models |
| `NEUROIMAGING_DB_PATH` | `data/patients.sqlite` | Patient database |

---

## The clinical PDF and CDISC standards

The PDF contains a title page, the MNE brain-anatomy figures (when the pipeline made them), the percentile-for-age tables (out-of-range regions
shaded), optional scatter plots, and two tables that follow CDISC standards:

- **SDTM**: the **observed** measurements, in a sponsor-defined Findings domain
  **`ZB`** ("Brain Volumetry/Morphometry"), since base SDTM has no domain for
  quantitative neuroimaging. Variables: `STUDYID, DOMAIN, USUBJID, ZBSEQ, ZBTESTCD,
  ZBTEST, ZBCAT, ZBORRES, ZBORRESU, ZBSTRESC, ZBSTRESN, ZBSTRESU, ZBMETHOD,
  VISITNUM, VISIT`.
- **ADaM**: **analysis-ready** data in Basic Data Structure form. Variables: `AVAL`
  (the measured value), `ANRLO`/`ANRHI` (95% reference interval for the patient's
  age), `ANRIND` (`LOW`/`NORMAL`/`HIGH`), `PCTLREF` (percentile for age), `AGE`,
  `AGEGR1` (`< 40` / `≥ 40 years`), `NREF` (number of control subjects behind the
  model).

---

## Statistical method (unchanged from the original)

For each brain-region measurement within an age group, an ordinary least-squares
line `value ~ age` is fitted on the control cohort. The patient's 95% **prediction**
interval at their exact age gives the reference range. Their percentile is found by
linear interpolation between the 2.5th and 97.5th percentiles of that interval,
clamped to `[0, 100]`.

> **Note.** The bundled reference cohort is modest (a few hundred controls, and very
> few under 40), so some metrics can't be fitted for the youngest age group. Treat
> the shipped models as a working demonstration, and refit with your full cohort,
> processed with the same FreeSurfer version as your patients, before clinical use.

---

## Testing

```bash
bin/neuroimaging test
```

This builds a stub FreeSurfer 8.2.0 install, whose `recon-all`, `segmentHA_T1.sh`
and `segmentBS.sh` write outputs in the real FS 8 file formats, plus a synthetic
DICOM session (an MPRAGE, a post-contrast T1 and a localizer). When MNE is
installed, the stub also writes a synthetic anatomy (T1 volume, white and pial
surfaces, aparc annotation). It then runs the whole pipeline and checks:

- the T1 choice and the age and sex read from DICOM;
- that the tables and PDF are written, and that a re-run doesn't redo recon-all;
- that the MNE 2D and 3D figures and the HTML report are made and embedded in the PDF;
- the FS 8 → FS 6 name mapping and left/right labels;
- that the patient is stored in the database.

---

## Repository layout

```
.
├── setup.sh              # ONE-COMMAND setup of everything (Ubuntu 24.04)
├── setup.conf.example    # optional settings for setup.sh
├── bin/                  # neuroimaging CLI, ingest_subject.R, export_tables.R
├── pipeline/             # FreeSurfer pipeline, visualize.sh (MNE), check_environment.sh, lib/
├── install/              # install_ubuntu24.sh
├── R/                    # parsing, FS harmonisation, models, reports, CDISC, DB, jobs
├── app.R  plumber.R  global.R  run_app.R  run_api.R  entrypoint.sh
├── data/reference/       # control cohorts batches/{ICBM,PPMI,ADNI}/ + region-name maps
├── examples/sample_subject/
├── tests/                # stub-FreeSurfer end-to-end test
├── freesurfer_license/   # put license.txt here for Docker (git-ignored)
├── legacy/               # original scripts (reference only)
├── Dockerfile            # ubuntu:24.04, optional FreeSurfer 8.2.0
└── docker-compose.yml
```
