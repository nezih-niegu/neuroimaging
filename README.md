# Neuroimaging Normative Reference — Shiny app + web service

A rebuild of the original Python/R/bash neuroimaging pipeline as an **R Shiny
frontend backed by a plumber REST web service and a patient database**.

The original project ([`legacy/`](legacy/)) used FreeSurfer to turn a subject's
MRI into brain-region measurements, then Python scripts fit linear regression
models on control cohorts (ICBM / PPMI / ADNI), compared a single patient to
those normative distributions, and emitted an HTML/PDF percentile report.

This version keeps that exact statistical approach and the entire FreeSurfer
processing pipeline, and adds:

- an **R Shiny frontend** to upload one new patient's FreeSurfer stats and
  generate their percentile-for-age insights interactively;
- a **plumber REST API** ("web service") that owns the modelling and the
  database, so the Shiny app is just one of many possible clients;
- a **SQLite patient database** — every new patient is stored alongside the
  cohort and stays queryable;
- a **clinical PDF report** whose tabulated data follows the CDISC **SDTM** and
  **ADaM** standards;
- **Docker** packaging for one-command startup.

---

## What each piece does

| File | Role | Legacy equivalent |
|------|------|-------------------|
| `R/parse_freesurfer.R` | Reads FreeSurfer `asegstats2table` / `aparcstats2table` / hippocampal / brainstem tables into tidy, subject-keyed data | file parsing inside `createPDFreport.py` |
| `R/reference_data.R` | Walks the control-cohort batches and joins measurements to age/sex demographics | the "join the batches" half of `batches_joinsANDlms.py` |
| `R/regression.R` | Fits `lm(value ~ age)` per brain region / age group, with 95% prediction intervals | the OLS + prediction-interval half of `batches_joinsANDlms.py` |
| `R/report.R` | Computes a new patient's percentile-for-age and flags out-of-range regions; scatter plots | `createPDFreport.py` / `scatter_*.R` |
| `R/cdisc.R` | Maps the report onto CDISC **SDTM** and **ADaM** datasets | *(new)* |
| `R/pdf_report.R` | Renders the deliverable multi-page clinical PDF | `pdfkit` output in `createPDFreport.py` |
| `R/db.R` | SQLite persistence for patients, reports and raw measurements | *(new)* |
| `plumber.R` | REST web service | *(new)* |
| `app.R` | Shiny frontend | *(new)* |

The FreeSurfer processing itself is unchanged and still lives in
[`legacy/recon_report.sh`](legacy/recon_report.sh); that script is what you run
on a scanner/workstation to turn DICOMs into the `*stats*.txt` files this app
consumes. The original Python scripts are preserved in
[`legacy/python_scripts/`](legacy/python_scripts/) for reference and provenance.

---

## Quick start (Docker — recommended)

```bash
docker compose up --build
```

If your Docker install uses the older standalone Compose, use the hyphenated
form instead: `docker-compose up --build`.

Then open:

- **Shiny app:** http://localhost:3838
- **REST API docs (Swagger):** http://localhost:8000/__docs__/

The patient database persists in the `neuroimaging_data` Docker volume.

Plain `docker` without compose:

```bash
docker build -t neuroimaging-shiny .
docker run -p 3838:3838 -p 8000:8000 -v neuroimaging_data:/app/data neuroimaging-shiny
```

The image is based on `rocker/r-ver`, which publishes **both `linux/amd64` and
`linux/arm64`** builds, so it builds natively on Apple Silicon (M-series) Macs
with no emulation. The first build compiles/downloads the R packages and
pre-fits the reference models, so allow several minutes; later builds are
cached.

> **If you ever hit** `no match for platform in manifest`, you're pulling an
> image tag that isn't published for your CPU architecture. Either use a
> multi-arch base (as this Dockerfile does) or force emulation:
> `DOCKER_DEFAULT_PLATFORM=linux/amd64 docker compose up --build`.

---

## Quick start (local R)

Requires R ≥ 4.2 and these packages:
`shiny, DT, ggplot2, DBI, RSQLite, plumber, httr, jsonlite, gridExtra`.

```r
install.packages(c("shiny","DT","ggplot2","DBI","RSQLite",
                   "plumber","httr","jsonlite","gridExtra"))
```

Start the web service in one terminal:

```bash
Rscript run_api.R          # serves http://127.0.0.1:8000
```

Start the Shiny app in another:

```bash
Rscript run_app.R          # serves http://127.0.0.1:3838
```

The first run builds the reference regression models from
`data/reference/batches/` and caches them to `data/reference_models.rds`
(rebuildable any time from the **Reference Models** tab or `POST /models/rebuild`).

---

## Using the app

1. Open the Shiny app and go to **New Patient**.
2. Enter a patient ID and age.
3. Upload that subject's FreeSurfer output files (the `*stats*.txt` files
   produced by `legacy/recon_report.sh`: `asegstats_vol.txt`,
   `lhaparc_/rhaparc_ vol|thick|area.txt`, and optionally
   `hipposubfield_vol.txt` / `brainstemstruct_vol.txt`). File names are
   auto-detected.
   A ready-made example is in [`examples/sample_subject/`](examples/sample_subject/).
4. Click **Process & preview** to see the percentile-for-age tables, the
   region scatter plot, and the **SDTM** and **ADaM** tabulations.
5. Click **Save to database** to store the patient, then **Download clinical
   PDF** for the report.

Saved patients are listed under **Patient Database**, where you can re-download
any patient's PDF.

---

## The clinical PDF and CDISC standards

The generated PDF contains a title page, the percentile-for-age tables (with
out-of-range regions shaded), optional scatter plots, and two
regulatory-standard tabulations:

### SDTM — Study Data Tabulation Model
The **observed** measurements, organised as a Findings-class domain. Because
quantitative neuroimaging has no dedicated base-SDTM domain, a sponsor-defined
Findings domain **`ZB`** ("Brain Volumetry/Morphometry") is used, following the
standard Findings variable conventions: `STUDYID, DOMAIN, USUBJID, ZBSEQ,
ZBTESTCD, ZBTEST, ZBCAT, ZBORRES, ZBORRESU, ZBSTRESC, ZBSTRESN, ZBSTRESU,
ZBMETHOD, VISITNUM, VISIT`.

### ADaM — Analysis Data Model
The **analysis-ready** data in Basic Data Structure (BDS) form, one row per
parameter. The normative reference interval maps directly onto the standard
analysis-range variables:

- `AVAL` — the patient's measured value
- `ANRLO` / `ANRHI` — the 95% reference interval for the patient's age
- `ANRIND` — reference-range indicator: `LOW` / `NORMAL` / `HIGH`
- `PCTLREF` — (custom) the percentile-for-age
- `AGE`, `AGEGR1` — age and its analysis grouping (`< 40` / `≥ 40 years`)
- `NREF` — number of control subjects behind the model

These are deliberately faithful to the CDISC variable names so the output can
drop into a clinical-study documentation package.

---

## REST API reference

Base URL: `http://localhost:8000`

| Method | Path | Description |
|--------|------|-------------|
| `GET`  | `/health` | Service health + loaded regions |
| `POST` | `/models/rebuild` | Rebuild the regression models from disk |
| `GET`  | `/patients` | List all patients |
| `POST` | `/patients` | Compute + store a new patient's report |
| `GET`  | `/patients/{id}` | One patient's demographics + report |
| `DELETE` | `/patients/{id}` | Delete a patient |
| `GET`  | `/patients/{id}/report.pdf` | Download the clinical PDF |
| `GET`  | `/patients/{id}/cdisc` | SDTM + ADaM datasets as JSON |

### Example: create a patient

`POST /patients` body:

```json
{
  "patient_id": "sub-00121",
  "display_name": "Example Patient",
  "age": 66,
  "sex": "M",
  "notes": "first visit",
  "stats": {
    "lh_vol":  {"lh_bankssts_volume": 2873, "lh_cuneus_volume": 3283 },
    "seg_vol": {"Left-Hippocampus": 3527.2 }
  }
}
```

`stats` keys are `lh_vol, rh_vol, lh_thick, rh_thick, lh_area, rh_area,
seg_vol, hippo_vol, brainstem_vol` — the same keys the parser produces from a
subject's FreeSurfer output directory.

```bash
curl -X POST http://localhost:8000/patients \
     -H 'Content-Type: application/json' \
     -d @patient.json

curl -o report.pdf http://localhost:8000/patients/sub-00121/report.pdf
```

---

## Configuration (environment variables)

| Variable | Default | Meaning |
|----------|---------|---------|
| `NEUROIMAGING_API_PORT` | `8000` | plumber API port |
| `NEUROIMAGING_APP_PORT` | `3838` | Shiny app port |
| `NEUROIMAGING_API_URL` | `http://127.0.0.1:8000` | where the app reaches the API (falls back to in-process computation if unreachable) |
| `NEUROIMAGING_REFERENCE_DIR` | `data/reference/batches` | control-cohort batches |
| `NEUROIMAGING_MODELS_PATH` | `data/reference_models.rds` | cached fitted models |
| `NEUROIMAGING_DB_PATH` | `data/patients.sqlite` | patient database |

---

## Statistical method (unchanged from the original)

For each brain-region measurement within an age group, an ordinary
least-squares line `value ~ age` is fit on the control cohort. A new patient's
95% **prediction** interval at their exact age gives the reference range; their
percentile is obtained by linearly interpolating their value between the 2.5th
and 97.5th percentiles of that interval (values are clamped to `[0, 100]`).
This is the same computation as the original `batches_joinsANDlms.py` /
`createPDFreport.py`, re-expressed continuously in age rather than via a
per-integer-age lookup table.

> **Note.** The bundled reference cohort is modest (a few hundred controls, and
> very few under 40), so the youngest age group has too few subjects to fit some
> metrics. Treat the shipped models as a working demonstration; refit with your
> full processed cohort for clinical use.

---

## Repository layout

```
.
├── app.R                 # Shiny frontend
├── plumber.R             # REST web service
├── global.R              # shared setup (sourced by both)
├── run_app.R / run_api.R # launchers
├── R/                    # processing, regression, reports, CDISC, DB
├── data/
│   └── reference/        # bundled control-cohort batches + region-name maps
├── examples/sample_subject/   # ready-to-upload demo stats files
├── legacy/               # original bash + Python + R scripts (unchanged)
├── Dockerfile
├── docker-compose.yml
└── entrypoint.sh
```
