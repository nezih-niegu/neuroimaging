# legacy/ (reference only)

These are the original scripts, kept as a record of the method. **Nothing in
the project runs them.**

| Legacy | Replaced by |
|---|---|
| `recon_report.sh` | `pipeline/neuroimaging-pipeline.sh` (`bin/neuroimaging process`) |
| `python_scripts/batches_joinsANDlms.py` | `R/reference_data.R` + `R/regression.R` |
| `python_scripts/createPDFreport*.py` | `R/report.R` + `R/pdf_report.R` + `R/cdisc.R` |
| `python_scripts/CSVs_with_report_names/` | `data/reference/region_names/` |
| `R_original/scatter_*.R` | `plot_reference_scatter()` in `R/report.R` |

`recon_report.sh` **does not work with FreeSurfer 7 or 8**, so it does not work
on Ubuntu 24.04 either, because FreeSurfer 8.x is the only version with an
Ubuntu 24 package:

- `recon-all -hippocampal-subfields-T1` now prints "the hippocampal subfield
  module is now in separate scripts" and exits with an error;
- `quantifyHippocampalSubfields.sh` / `quantifyBrainstemStructures.sh` are deprecated;
- it uses `dctable` for the patient age (not available on Ubuntu 24.04) and
  hard-codes `/home/neurocogn/...` paths.
