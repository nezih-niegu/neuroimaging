# -----------------------------------------------------------------------
# pdf_report.R
#
# Generates the deliverable clinical PDF - the R replacement for
# legacy/python_scripts/createPDFreport.py's pdfkit output.
#
# It uses grid / gridExtra table grobs written to a base pdf() device, so
# it needs NO LaTeX / wkhtmltopdf / headless-Chrome toolchain and runs
# unchanged inside the Docker image.
#
# The PDF contains, per report:
#   1. A title page (patient + study/CDISC metadata)
#   2. Percentile-for-age tables, one per region/metric, with
#      out-of-range regions highlighted
#   3. The SDTM Findings (ZB) tabulation
#   4. The ADaM BDS tabulation (with reference intervals + ANRIND)
# -----------------------------------------------------------------------

suppressPackageStartupMessages({
  library(grid)
  library(gridExtra)
})

.theme_default <- gridExtra::ttheme_default(
  core = list(fg_params = list(cex = 0.62), padding = grid::unit(c(2.4, 2.4), "mm")),
  colhead = list(fg_params = list(cex = 0.66, fontface = "bold"))
)

# Build a table grob, colouring rows where out_of_range/ANRIND is abnormal
.styled_table_grob <- function(df, flag_col = NULL, flag_test = NULL) {
  df_disp <- df
  # round numeric columns for display
  num <- vapply(df_disp, is.numeric, logical(1))
  df_disp[num] <- lapply(df_disp[num], function(x) ifelse(is.na(x), "", format(round(x, 2), trim = TRUE)))
  df_disp[] <- lapply(df_disp, function(x) { x[is.na(x)] <- ""; as.character(x) })

  g <- gridExtra::tableGrob(df_disp, rows = NULL, theme = .theme_default)

  if (!is.null(flag_col) && flag_col %in% colnames(df)) {
    flagged <- if (is.null(flag_test)) which(as.logical(df[[flag_col]])) else which(flag_test(df[[flag_col]]))
    for (r in flagged) {
      # tableGrob layout: header is row 1, data rows start at 2; there is
      # one "core-bg" cell per column, so shade every column in the row.
      idxs <- which(g$layout$t == r + 1 & g$layout$name == "core-bg")
      for (idx in idxs) {
        g$grobs[[idx]] <- grid::rectGrob(gp = grid::gpar(fill = "#fde0e0", col = "#f5b5b5"))
      }
    }
  }
  g
}

.title_page <- function(meta_lines) {
  grid::grid.newpage()
  grid::grid.text("Neuroimaging Normative Reference Report",
                  x = 0.5, y = 0.86, gp = grid::gpar(fontsize = 20, fontface = "bold"))
  grid::grid.text("Percentile-for-age brain morphometry vs ICBM / PPMI / ADNI controls",
                  x = 0.5, y = 0.80, gp = grid::gpar(fontsize = 11, col = "grey30"))
  grid::grid.text(paste(meta_lines, collapse = "\n"),
                  x = 0.5, y = 0.5, gp = grid::gpar(fontsize = 12), just = "centre")
  grid::grid.text(paste0("Generated ", format(Sys.time(), "%Y-%m-%d %H:%M")),
                  x = 0.5, y = 0.08, gp = grid::gpar(fontsize = 9, col = "grey50"))
}

.section_page <- function(title, grob, subtitle = NULL) {
  grid::grid.newpage()
  grid::grid.text(title, x = 0.5, y = 0.965, gp = grid::gpar(fontsize = 14, fontface = "bold"))
  yb <- 0.93
  if (!is.null(subtitle)) {
    grid::grid.text(subtitle, x = 0.5, y = 0.93, gp = grid::gpar(fontsize = 9, col = "grey40"))
    yb <- 0.90
  }
  vp <- grid::viewport(x = 0.5, y = yb / 2, width = 0.96, height = yb)
  grid::pushViewport(vp)
  grid::grid.draw(grob)
  grid::popViewport()
}

# Split a big data.frame into page-sized chunks so wide/long tables fit
.chunk_rows <- function(df, rows_per_page = 28) {
  if (nrow(df) == 0) return(list())
  split(df, ceiling(seq_len(nrow(df)) / rows_per_page))
}

#' Generate the full PDF report to `output_path`
#'
#' @param full_report list of per-region-metric data.frames (from
#'   build_full_report())
#' @param patient meta list: patient_id, display_name, age, sex, notes
#' @param cdisc  output of build_cdisc(); if NULL it is built here
#' @param plots  optional named list of ggplot objects to embed
#' @param output_path where to write the PDF
generate_pdf_report <- function(full_report, patient, cdisc = NULL,
                                 plots = NULL, output_path = tempfile(fileext = ".pdf")) {
  if (is.null(cdisc)) {
    cdisc <- build_cdisc(full_report, patient$patient_id, patient$age,
                          sex = patient$sex %||% NA)
  }

  grDevices::pdf(output_path, width = 11.7, height = 8.3, onefile = TRUE)  # A4 landscape
  on.exit(grDevices::dev.off())

  # 1. Title page
  meta_lines <- c(
    paste0("Patient ID: ", patient$patient_id),
    if (!is.null(patient$display_name)) paste0("Name: ", patient$display_name),
    paste0("Age: ", patient$age, " years   (group: ", cdisc$meta$age_group, ")"),
    if (!is.null(patient$sex) && !is.na(patient$sex)) paste0("Sex: ", patient$sex),
    "",
    paste0("STUDYID: ", cdisc$meta$studyid),
    paste0("USUBJID: ", cdisc$meta$usubjid),
    paste0("Analysis parameters: ", cdisc$meta$n_params),
    if (!is.null(patient$notes) && nzchar(patient$notes %||% "")) paste0("Notes: ", patient$notes)
  )
  .title_page(meta_lines)

  # 2. Percentile tables, one region/metric per page (chunked if long)
  cols <- c("label", "result", "unit", "low_ref", "high_ref", "percentile", "out_of_range")
  for (key in names(full_report)) {
    df <- full_report[[key]]
    if (is.null(df) || nrow(df) == 0) next
    show <- df[, intersect(cols, colnames(df)), drop = FALSE]
    colnames(show) <- sub("^label$", "Region",
                       sub("^result$", "Result",
                       sub("^unit$", "Unit",
                       sub("^low_ref$", "Ref Low",
                       sub("^high_ref$", "Ref High",
                       sub("^percentile$", "Pctile",
                       sub("^out_of_range$", "Flag", colnames(show))))))))
    parts <- strsplit(key, "_")[[1]]
    title <- paste0(REGION_LABELS[[parts[1]]] %||% parts[1], " - ",
                    toupper(substring(paste(parts[-1], collapse = "_"), 1, 1)),
                    substring(paste(parts[-1], collapse = "_"), 2))
    for (chunk in .chunk_rows(show)) {
      g <- .styled_table_grob(chunk, flag_col = "Flag", flag_test = function(x) as.logical(x))
      .section_page(paste("Percentile-for-age:", title), g,
                    subtitle = "Rows shaded red are outside the 95% reference interval for age")
    }
  }

  # 3. Embedded plots (optional)
  if (!is.null(plots) && length(plots)) {
    for (nm in names(plots)) {
      grid::grid.newpage()
      print(plots[[nm]], newpage = FALSE)
    }
  }

  # 4. SDTM tabulation
  if (nrow(cdisc$sdtm) > 0) {
    sdtm_cols <- c("USUBJID", "ZBTESTCD", "ZBTEST", "ZBCAT", "ZBORRES",
                    "ZBORRESU", "ZBSTRESN", "VISIT")
    sd <- cdisc$sdtm[, intersect(sdtm_cols, colnames(cdisc$sdtm)), drop = FALSE]
    for (chunk in .chunk_rows(sd)) {
      .section_page("SDTM - Findings Domain (ZB): Brain Morphometry",
                    .styled_table_grob(chunk),
                    subtitle = "Study Data Tabulation Model - observed results (sponsor domain ZB)")
    }
  }

  # 5. ADaM tabulation
  if (nrow(cdisc$adam) > 0) {
    adam_cols <- c("USUBJID", "PARAMCD", "PARAM", "AVAL", "ANRLO", "ANRHI",
                    "ANRIND", "PCTLREF", "AGEGR1")
    ad <- cdisc$adam[, intersect(adam_cols, colnames(cdisc$adam)), drop = FALSE]
    for (chunk in .chunk_rows(ad)) {
      g <- .styled_table_grob(chunk, flag_col = "ANRIND",
                               flag_test = function(x) x %in% c("LOW", "HIGH"))
      .section_page("ADaM - Basic Data Structure (BDS)", g,
                    subtitle = "Analysis Data Model - ANRLO/ANRHI = reference interval; ANRIND = LOW/NORMAL/HIGH")
    }
  }

  invisible(output_path)
}

`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a
