# -----------------------------------------------------------------------
# freesurfer_native.R
#
# Reads a FreeSurfer subject directory ($SUBJECTS_DIR/<subject>) directly,
# without needing asegstats2table / aparcstats2table to be installed, and
# harmonises region names across FreeSurfer versions.
#
# Why harmonisation matters
# -------------------------
# The bundled ICBM / PPMI / ADNI reference cohort was processed in 2020
# with FreeSurfer 6. Patients processed today on Ubuntu 24.04 run
# FreeSurfer 7.x / 8.x, which renamed or re-split some structures:
#
#   * aseg:  "Left-Thalamus-Proper"  ->  "Left-Thalamus"   (FS >= 7)
#   * hippocampal subfields (segmentHA_T1.sh, FS >= 7) split several
#     subfields into "-head" and "-body" parts, e.g. "CA1-head" +
#     "CA1-body". FS 6 (the reference) reported them whole: "CA1".
#
# Without harmonisation those regions silently disappear from the report
# because no reference model has the new name. harmonize_fs_names() maps
# every measurement onto the reference (FS 6) naming, summing head/body
# parts where needed, and is applied to BOTH reference tables and patient
# data so the two always line up.
# -----------------------------------------------------------------------

# aseg structures renamed between FS 6 and FS 7+ (new name -> reference name)
.ASEG_RENAMES <- c(
  "Left-Thalamus"  = "Left-Thalamus-Proper",
  "Right-Thalamus" = "Right-Thalamus-Proper"
)

# Hippocampal subfields that FS >= 7 reports as <name>-head + <name>-body
.HIPPO_SPLIT <- c("subiculum", "CA1", "CA3", "CA4", "presubiculum",
                  "molecular_layer_HP", "GC-ML-DG")
.HIPPO_FS6_ORDER <- c("Hippocampal_tail", "subiculum", "CA1", "hippocampal-fissure",
                      "presubiculum", "parasubiculum", "molecular_layer_HP", "GC-ML-DG",
                      "CA3", "CA4", "fimbria", "HATA", "Whole_hippocampus")
# FS >= 7 extras with no FS 6 equivalent - dropped to keep the report
# aligned with the reference models.
.HIPPO_DROP <- c("Whole_hippocampal_body", "Whole_hippocampal_head",
                 "HP-tail")

#' Map a named measurement vector onto the reference (FS 6) region names
#'
#' @param values named numeric vector of one subject's measurements
#' @param region "lh","rh","seg","hippo","brainstem"
#' @return named numeric vector using reference names
harmonize_fs_names <- function(values, region) {
  if (length(values) == 0) return(values)
  nm <- names(values)

  if (region == "seg") {
    hit <- nm %in% names(.ASEG_RENAMES)
    nm[hit] <- .ASEG_RENAMES[nm[hit]]
    names(values) <- nm
    return(values[!duplicated(names(values))])
  }

  if (region == "hippo") {
    out <- values
    for (side in c("left_", "right_")) {
      for (base in .HIPPO_SPLIT) {
        head <- paste0(side, base, "-head")
        body <- paste0(side, base, "-body")
        whole <- paste0(side, base)
        if (!(whole %in% names(out)) && (head %in% names(out) || body %in% names(out))) {
          out[[whole]] <- sum(out[intersect(c(head, body), names(out))])
        }
        out <- out[!(names(out) %in% c(head, body))]
      }
      out <- out[!(names(out) %in% paste0(side, .HIPPO_DROP))]
    }
    # FreeSurfer 6 row order (left side, then right side)
    canon <- c(paste0("left_", .HIPPO_FS6_ORDER), paste0("right_", .HIPPO_FS6_ORDER))
    return(out[c(intersect(canon, names(out)), setdiff(names(out), canon))])
  }

  values
}

#' Harmonise every measurement column of a parsed stats table
harmonize_fs_table <- function(tbl, region) {
  if (!(region %in% c("seg", "hippo"))) return(tbl)
  meas <- setdiff(colnames(tbl), "subject_id")
  if (region == "seg") {
    hit <- meas %in% names(.ASEG_RENAMES)
    if (any(hit)) {
      new <- meas
      new[hit] <- .ASEG_RENAMES[meas[hit]]
      keep <- !duplicated(new)
      tbl <- tbl[, c("subject_id", meas[keep]), drop = FALSE]
      colnames(tbl) <- c("subject_id", new[keep])
    }
    return(tbl)
  }
  # hippo: apply row-wise via the vector helper
  rows <- lapply(seq_len(nrow(tbl)), function(i) {
    v <- suppressWarnings(as.numeric(tbl[i, meas]))
    names(v) <- meas
    harmonize_fs_names(v, "hippo")
  })
  cols <- unique(unlist(lapply(rows, names)))
  out <- data.frame(subject_id = tbl$subject_id, stringsAsFactors = FALSE)
  for (cc in cols) out[[cc]] <- vapply(rows, function(v) if (cc %in% names(v)) v[[cc]] else NA_real_, numeric(1))
  attributes(out)[c("region", "metric")] <- attributes(tbl)[c("region", "metric")]
  out
}

# ---- native .stats readers ------------------------------------------------

.read_colheaders_table <- function(path) {
  lines <- readLines(path, warn = FALSE)
  hdr <- grep("^#\\s*ColHeaders", lines, value = TRUE)
  if (length(hdr) == 0) stop("No '# ColHeaders' line in ", path)
  cols <- strsplit(trimws(sub("^#\\s*ColHeaders", "", hdr[1])), "\\s+")[[1]]
  body <- lines[!grepl("^\\s*#", lines) & nzchar(trimws(lines))]
  if (length(body) == 0) return(as.data.frame(setNames(replicate(length(cols), character(), simplify = FALSE), cols)))
  utils::read.table(text = body, header = FALSE, stringsAsFactors = FALSE,
                    col.names = cols, fill = TRUE, comment.char = "")
}

#' Read $SUBJECTS_DIR/<subj>/stats/aseg.stats -> named volume vector
#' (names as asegstats2table writes them, harmonised to reference names)
read_aseg_stats <- function(path) {
  df <- .read_colheaders_table(path)
  v <- as.numeric(df$Volume_mm3)
  names(v) <- df$StructName
  # whole-brain measures from the "# Measure" header (CortexVol,
  # TotalGrayVol, SubCortGrayVol, ...) - asegstats2table includes these
  v <- c(.read_header_measures(path), v)
  v <- v[!grepl(.FS_SUMMARY_DROP, names(v), ignore.case = TRUE)]
  harmonize_fs_names(v, "seg")
}

# Summary columns excluded from reports (same rule as read_fs_table())
.FS_SUMMARY_DROP <- "BrainSeg|eTIV|MaskVol|SupraTentorial|SurfaceHoles|WhiteSurfArea|MeanThickness$|NumVert$"

#' Parse "# Measure <struct>, <name>, <description>, <value>, <unit>" lines
.read_header_measures <- function(path) {
  lines <- grep("^#\\s*Measure\\s", readLines(path, warn = FALSE), value = TRUE)
  if (length(lines) == 0) return(numeric())
  parts <- strsplit(sub("^#\\s*Measure\\s+", "", lines), ",\\s*")
  ok <- vapply(parts, length, integer(1)) >= 4
  v <- vapply(parts[ok], function(p) suppressWarnings(as.numeric(p[4])), numeric(1))
  names(v) <- vapply(parts[ok], `[`, character(1), 2)
  v[!is.na(v)]
}

#' Read $SUBJECTS_DIR/<subj>/stats/?h.aparc.stats -> list(vol, thick, area)
#' with names exactly as aparcstats2table writes them
#' (e.g. lh_bankssts_volume / lh_bankssts_thickness / lh_bankssts_area)
read_aparc_stats <- function(path, hemi) {
  df <- .read_colheaders_table(path)
  mk <- function(col, suffix) {
    v <- as.numeric(df[[col]])
    names(v) <- paste0(hemi, "_", df$StructName, "_", suffix)
    v
  }
  out <- list(vol = mk("GrayVol", "volume"),
              thick = mk("ThickAvg", "thickness"),
              area = mk("SurfArea", "area"))
  # aparcstats2table adds the hemisphere mean thickness as a column
  hm <- .read_header_measures(path)
  if ("MeanThickness" %in% names(hm)) {
    out$thick[[paste0(hemi, "_MeanThickness_thickness")]] <- hm[["MeanThickness"]]
  }
  out
}

#' Read a segmentHA_T1.sh / segmentBS.sh volumes file
#' ("<name> <volume>" per line). Returns a named numeric vector.
read_subregion_volumes <- function(path, prefix = "") {
  lines <- trimws(readLines(path, warn = FALSE))
  lines <- lines[nzchar(lines) & !startsWith(lines, "#")]
  parts <- strsplit(lines, "\\s+")
  v <- vapply(parts, function(p) as.numeric(p[length(p)]), numeric(1))
  names(v) <- paste0(prefix, vapply(parts, `[`, character(1), 1))
  v
}

#' Find the newest-version file matching a pattern (e.g. v21 vs v22)
.newest_version_file <- function(dir, pattern) {
  hits <- list.files(dir, pattern = pattern, full.names = TRUE)
  if (length(hits) == 0) return(NA_character_)
  ver <- suppressWarnings(as.numeric(sub(".*\\.v([0-9]+)\\..*", "\\1", basename(hits))))
  hits[order(ver, decreasing = TRUE)][1]
}

#' Locate the hippocampal-subfield and brainstem volume files of a subject
find_subregion_files <- function(subject_dir) {
  mri <- file.path(subject_dir, "mri")
  list(
    lh_hippo  = .newest_version_file(mri, "^lh\\.hippoSfVolumes-T1\\.v[0-9]+\\.txt$"),
    rh_hippo  = .newest_version_file(mri, "^rh\\.hippoSfVolumes-T1\\.v[0-9]+\\.txt$"),
    brainstem = .newest_version_file(mri, "^brainstemSsVolumes\\.v[0-9]+\\.txt$")
  )
}

#' Read ONE processed FreeSurfer subject directory directly
#'
#' @param subject_dir $SUBJECTS_DIR/<subject>
#' @return named list keyed lh_vol, rh_vol, lh_thick, rh_thick, lh_area,
#'   rh_area, seg_vol, hippo_vol, brainstem_vol (same shape as
#'   read_subject_stats_dir()), harmonised to the reference naming
read_freesurfer_subject <- function(subject_dir) {
  stats_dir <- file.path(subject_dir, "stats")
  if (!dir.exists(stats_dir)) stop("Not a FreeSurfer subject (no stats/ folder): ", subject_dir)
  out <- list()
  for (hemi in c("lh", "rh")) {
    f <- file.path(stats_dir, paste0(hemi, ".aparc.stats"))
    if (!file.exists(f)) next
    a <- read_aparc_stats(f, hemi)
    out[[paste0(hemi, "_vol")]] <- a$vol
    out[[paste0(hemi, "_thick")]] <- a$thick
    out[[paste0(hemi, "_area")]] <- a$area
  }
  aseg <- file.path(stats_dir, "aseg.stats")
  if (file.exists(aseg)) out[["seg_vol"]] <- read_aseg_stats(aseg)

  sr <- find_subregion_files(subject_dir)
  if (!is.na(sr$lh_hippo) && !is.na(sr$rh_hippo)) {
    v <- c(read_subregion_volumes(sr$lh_hippo, "left_"),
           read_subregion_volumes(sr$rh_hippo, "right_"))
    out[["hippo_vol"]] <- harmonize_fs_names(v, "hippo")
  }
  if (!is.na(sr$brainstem)) {
    out[["brainstem_vol"]] <- read_subregion_volumes(sr$brainstem)
  }
  if (length(out) == 0) stop("No readable FreeSurfer stats found in ", stats_dir)
  # order to match the app's canonical key order
  canon <- c("lh_vol", "rh_vol", "lh_thick", "rh_thick", "lh_area", "rh_area",
             "seg_vol", "hippo_vol", "brainstem_vol")
  out[intersect(canon, names(out))]
}

#' Write the legacy-format per-subject tables (the same files
#' recon_report.sh produced and the Shiny upload accepts) from a
#' subject's measurements. Used as a fallback when FreeSurfer's own
#' *stats2table tools are unavailable or fail.
export_subject_tables <- function(subject_stats, subject_id, out_dir) {
  dir.create(out_dir, recursive = TRUE, showWarnings = FALSE)
  spec <- list(
    lh_vol = c("lhaparc_vol.txt", "lh.aparc.volume", "\t"),
    rh_vol = c("rhaparc_vol.txt", "rh.aparc.volume", "\t"),
    lh_thick = c("lhaparc_thick.txt", "lh.aparc.thickness", "\t"),
    rh_thick = c("rhaparc_thick.txt", "rh.aparc.thickness", "\t"),
    lh_area = c("lhaparc_area.txt", "lh.aparc.area", "\t"),
    rh_area = c("rhaparc_area.txt", "rh.aparc.area", "\t"),
    seg_vol = c("asegstats_vol.txt", "Measure:volume", "\t"),
    hippo_vol = c("hipposubfield_vol.txt", "Subject", " "),
    brainstem_vol = c("brainstemstruct_vol.txt", "Subject", " ")
  )
  written <- character()
  for (key in intersect(names(spec), names(subject_stats))) {
    s <- spec[[key]]
    v <- subject_stats[[key]]
    path <- file.path(out_dir, s[1])
    writeLines(c(paste(c(s[2], names(v)), collapse = s[3]),
                 paste(c(subject_id, format(v, digits = 15, scientific = FALSE, trim = TRUE)), collapse = s[3])),
               path)
    written <- c(written, path)
  }
  invisible(written)
}

#' List processed subjects (those with stats/aseg.stats) in a SUBJECTS_DIR
list_freesurfer_subjects <- function(subjects_dir = default_subjects_dir()) {
  if (is.na(subjects_dir) || !dir.exists(subjects_dir)) return(character())
  d <- list.dirs(subjects_dir, recursive = FALSE, full.names = FALSE)
  d <- d[!d %in% c("fsaverage", "fsaverage5", "fsaverage6", "fsaverage3",
                   "fsaverage4", "bert", "cvs_avg35", "cvs_avg35_inMNI152",
                   "lh.EC_average", "rh.EC_average", "V1_average")]
  d[file.exists(file.path(subjects_dir, d, "stats", "aseg.stats"))]
}

default_subjects_dir <- function() {
  sd <- Sys.getenv("NEUROIMAGING_SUBJECTS_DIR", unset = Sys.getenv("SUBJECTS_DIR", unset = ""))
  if (!nzchar(sd)) sd <- file.path("data", "freesurfer_subjects")
  sd
}
