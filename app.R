# -----------------------------------------------------------------------
# app.R - Shiny frontend.
#
# Talks to the plumber web service (plumber.R / run_api.R) over HTTP to
# compute and persist each new patient's report, so the same "insights"
# logic is available to any other client of the API too. If the API is
# not reachable, it transparently falls back to calling the R functions
# in R/ directly, so the app still works standalone.
# -----------------------------------------------------------------------

source("global.R")
library(httr)
# NB: we deliberately do NOT library(jsonlite) here - it exports a
# validate() that would mask shiny::validate(), which the app uses. We
# reference jsonlite functions with the jsonlite:: prefix instead.

API_URL <- Sys.getenv("NEUROIMAGING_API_URL", unset = "http://127.0.0.1:8000")

# DICOM sessions are uploaded as .zip on the FreeSurfer tab
options(shiny.maxRequestSize = as.numeric(Sys.getenv("NEUROIMAGING_MAX_UPLOAD_MB", "4096")) * 1024^2)

STATS_KEYS <- c("lh_vol", "rh_vol", "lh_thick", "rh_thick",
                 "lh_area", "rh_area", "seg_vol", "hippo_vol", "brainstem_vol")

# ---- helpers -----------------------------------------------------------

#' Classify a batch of uploaded files by FreeSurfer table type and parse
#' them with the same logic read_subject_stats_dir() uses on disk.
parse_uploaded_stats <- function(fileinput_df, subject_id) {
  tmp_dir <- file.path(tempdir(), paste0("upload_", subject_id, "_", as.integer(Sys.time())))
  dir.create(tmp_dir, showWarnings = FALSE)
  for (i in seq_len(nrow(fileinput_df))) {
    file.copy(fileinput_df$datapath[i], file.path(tmp_dir, fileinput_df$name[i]), overwrite = TRUE)
  }
  read_subject_stats_dir(tmp_dir, subject_id)
}

#' POST a new patient + stats to the API; fall back to local computation
#' if the web service isn't reachable.
submit_patient <- function(patient_id, display_name, age, sex, notes, subject_stats, models) {
  payload <- list(patient_id = patient_id, display_name = display_name, age = age,
                   sex = sex, notes = notes,
                   stats = lapply(subject_stats, as.list))

  resp <- tryCatch(
    httr::POST(paste0(API_URL, "/patients"),
               body = jsonlite::toJSON(payload, auto_unbox = TRUE, null = "null"),
               httr::content_type_json(), httr::timeout(15)),
    error = function(e) NULL)

  if (!is.null(resp) && httr::status_code(resp) == 200) {
    return(list(source = "api", report = jsonlite::fromJSON(httr::content(resp, "text", encoding = "UTF-8"),
                                                              simplifyVector = FALSE)$report))
  }

  # Fallback: compute + save locally
  full_report <- build_full_report(subject_stats, age, models, NAMES_DIR)
  con <- db_connect(DB_PATH)
  on.exit(DBI::dbDisconnect(con))
  db_upsert_patient(con, patient_id, display_name, age, sex, notes)
  db_save_report(con, patient_id, subject_stats, full_report)
  list(source = "local", report = full_report)
}

report_list_to_df <- function(report) {
  # report may come back either as data.frames (local) or lists-of-lists (API/JSON)
  to_df <- function(x) if (is.data.frame(x)) x else as.data.frame(do.call(rbind, lapply(x, as.data.frame)))
  lapply(report, function(x) if (length(x)) to_df(x) else data.frame())
}

fmt_key <- function(key) {
  parts <- strsplit(key, "_")[[1]]
  paste0(REGION_LABELS[[parts[1]]] %||% parts[1], " - ", paste(toupper(substring(parts[-1], 1, 1)),
                                                                 substring(parts[-1], 2), sep = "", collapse = " "))
}
`%||%` <- function(a, b) if (is.null(a) || (length(a) == 1 && is.na(a))) b else a

# ---- UI ------------------------------------------------------------------

ui <- navbarPage(
  title = "Neuroimaging Normative Reference",
  id = "main_nav",
  theme = NULL,

  tabPanel("New Patient",
    sidebarLayout(
      sidebarPanel(
        width = 4,
        h4("Patient"),
        textInput("patient_id", "Patient ID", placeholder = "e.g. sub-00121"),
        textInput("display_name", "Display name (optional)"),
        numericInput("age", "Age (years)", value = 60, min = 0, max = 110),
        selectInput("sex", "Sex", choices = c("Unknown" = "", "F", "M")),
        textAreaInput("notes", "Notes (optional)", rows = 2),
        hr(),
        h4("FreeSurfer stats files"),
        helpText("Upload the stats tables for this subject written by ",
                 "pipeline/neuroimaging-pipeline.sh (asegstats_vol, ",
                 "lhaparc_/rhaparc_ vol|thick|area, hipposubfield_vol, ",
                 "brainstemstruct_vol). File names are auto-detected. ",
                 "To process raw MRI or load a subject straight from ",
                 "SUBJECTS_DIR, use the FreeSurfer tab."),
        fileInput("stat_files", NULL, multiple = TRUE, accept = c(".txt")),
        actionButton("process_btn", "Process & preview", icon = icon("play"), class = "btn-primary"),
        br(), br(),
        actionButton("save_btn", "Save to database", icon = icon("save"), class = "btn-success"),
        br(), br(),
        downloadButton("download_pdf", "Download clinical PDF (SDTM + ADaM)", class = "btn-info"),
        br(), br(),
        verbatimTextOutput("status_msg")
      ),
      mainPanel(
        width = 8,
        tabsetPanel(
          tabPanel("Percentile report",
            br(),
            uiOutput("report_tabs_ui"),
            hr(),
            h4("Region plot"),
            fluidRow(
              column(6, selectInput("plot_key", "Region / metric", choices = STATS_KEYS)),
              column(6, selectInput("plot_column", "Brain region", choices = NULL))
            ),
            plotOutput("region_plot", height = "380px")
          ),
          tabPanel("SDTM (ZB)",
            br(),
            helpText("Study Data Tabulation Model - Findings-class domain (sponsor code ZB), observed results."),
            DTOutput("sdtm_table")
          ),
          tabPanel("ADaM (BDS)",
            br(),
            helpText("Analysis Data Model - Basic Data Structure. ANRLO/ANRHI = 95% reference interval for age; ANRIND = LOW/NORMAL/HIGH."),
            DTOutput("adam_table")
          )
        )
      )
    )
  ),

  tabPanel("Patient Database",
    fluidRow(
      column(12,
        actionButton("refresh_db_btn", "Refresh", icon = icon("rotate")),
        br(), br(),
        DTOutput("patients_table"),
        hr(),
        uiOutput("selected_pdf_ui"),
        h4("Selected patient's saved report"),
        uiOutput("selected_report_ui")
      )
    )
  ),

  tabPanel("FreeSurfer",
    fluidRow(
      column(5,
        h4("FreeSurfer on this server"),
        verbatimTextOutput("fs_status"),
        actionButton("fs_status_btn", "Re-check", icon = icon("rotate")),
        hr(),
        h4("Process a new scan"),
        helpText("Runs pipeline/neuroimaging-pipeline.sh: DICOM -> NIfTI -> recon-all -> ",
                 "hippocampal subfields + brainstem -> report. recon-all takes several hours; ",
                 "when the run succeeds the patient appears in the Patient Database."),
        textInput("fs_patient_id", "Patient / subject ID", placeholder = "e.g. sub-00121"),
        fluidRow(
          column(6, numericInput("fs_age", "Age (blank = read from DICOM)", value = NA, min = 1, max = 120)),
          column(6, selectInput("fs_sex", "Sex", choices = c("From DICOM" = "", "F", "M")))
        ),
        radioButtons("fs_input_mode", "Input", inline = TRUE,
                     choices = c("Upload DICOM .zip" = "zip", "Folder on server" = "path")),
        conditionalPanel("input.fs_input_mode == 'zip'",
          fileInput("fs_dicom_zip", NULL, accept = ".zip")),
        conditionalPanel("input.fs_input_mode == 'path'",
          textInput("fs_dicom_path", NULL, placeholder = "data/incoming/<subject>/...")),
        fluidRow(
          column(6, numericInput("fs_threads", "Threads", value = max(1, parallel::detectCores() - 1), min = 1)),
          column(6, br(), checkboxInput("fs_subregions", "Hippocampus + brainstem", TRUE))
        ),
        actionButton("fs_start_btn", "Start FreeSurfer run", icon = icon("brain"), class = "btn-primary"),
        br(), br(),
        verbatimTextOutput("fs_start_msg"),
        hr(),
        h4("Load an already-processed subject"),
        helpText("Reads stats straight from SUBJECTS_DIR (no FreeSurfer needed) and opens ",
                 "the result on the New Patient tab, where you can review and save it."),
        selectInput("fs_existing_subject", "Subject in SUBJECTS_DIR", choices = NULL),
        numericInput("fs_existing_age", "Age (years)", value = 60, min = 1, max = 120),
        selectInput("fs_existing_sex", "Sex", choices = c("Unknown" = "", "F", "M")),
        actionButton("fs_load_btn", "Load into New Patient", icon = icon("file-import"), class = "btn-success")
      ),
      column(7,
        h4("Pipeline runs"),
        actionButton("fs_jobs_refresh", "Refresh", icon = icon("rotate")),
        br(), br(),
        DTOutput("fs_jobs_table"),
        h5("Log of the selected run"),
        verbatimTextOutput("fs_job_log"),
        hr(),
        h4("Brain visualisation (MNE-Python)"),
        helpText("White/pial surfaces over the T1 (checks that FreeSurfer placed them correctly) ",
                 "and the 3D Desikan-Killiany parcellation the report is computed on. ",
                 "Made automatically by each pipeline run; regenerate any time."),
        fluidRow(
          column(6, selectInput("qc_subject", "Subject", choices = NULL)),
          column(6, br(), actionButton("qc_generate_btn", "Generate / refresh", icon = icon("cube")))
        ),
        checkboxInput("qc_3d", "Include 3D render", TRUE),
        verbatimTextOutput("qc_msg"),
        uiOutput("qc_images_ui"),
        downloadButton("qc_html_dl", "Download interactive MNE report (HTML)")
      )
    )
  ),

  tabPanel("Reference Models",
    fluidRow(
      column(12,
        p("The regression models are fit from the ICBM / PPMI / ADNI control ",
          "cohorts in the reference folder, exactly as in ",
          "legacy/python_scripts/batches_joinsANDlms.py, but re-implemented ",
          "as one lm(value ~ age) per brain region / age group in R/regression.R."),
        h4("Reference cohorts"),
        helpText("Folder: ", code(normalizePath(REFERENCE_DIR)), ". One subfolder per cohort ",
                 "(ICBM/, PPMI/, ADNI/...) with FreeSurfer stats tables and a <COHORT>_*.csv ",
                 "giving Subject + Age. Only subjects with an age are used in the models."),
        DTOutput("cohort_table"),
        br(),
        actionButton("rebuild_btn", "(Re)build reference models", icon = icon("gears"), class = "btn-warning"),
        br(), br(),
        verbatimTextOutput("rebuild_log"),
        DTOutput("fit_summary_table")
      )
    )
  )
)

# ---- server ----------------------------------------------------------------

server <- function(input, output, session) {

  models_rv <- reactiveVal(load_or_build_models())
  stats_rv <- reactiveVal(NULL)      # subject_stats list
  report_rv <- reactiveVal(NULL)     # list of data.frames
  status_rv <- reactiveVal("")

  # ---- New Patient tab ----

  observeEvent(input$process_btn, {
    req(input$stat_files, input$patient_id)
    status_rv("Parsing uploaded stats files...")
    subj <- tryCatch(parse_uploaded_stats(input$stat_files, input$patient_id),
                      error = function(e) { status_rv(paste("Error:", conditionMessage(e))); NULL })
    if (is.null(subj) || length(subj) == 0) {
      status_rv("No recognizable FreeSurfer stats files were found in the upload.")
      return(invisible())
    }
    stats_rv(subj)
    full_report <- build_full_report(subj, input$age, models_rv(), NAMES_DIR)
    report_rv(full_report)
    status_rv(sprintf("Parsed %d stats table(s); report ready for %s.", length(subj), input$patient_id))
    updateSelectInput(session, "plot_key", choices = names(subj))
  })

  observeEvent(input$save_btn, {
    req(stats_rv(), input$patient_id)
    status_rv("Saving...")
    res <- tryCatch(
      submit_patient(input$patient_id, ifelse(nzchar(input$display_name), input$display_name, input$patient_id),
                      input$age, ifelse(nzchar(input$sex), input$sex, NA), input$notes,
                      stats_rv(), models_rv()),
      error = function(e) NULL)
    if (is.null(res)) {
      status_rv("Save failed.")
    } else {
      report_rv(report_list_to_df(res$report))
      status_rv(sprintf("Saved patient '%s' (%s).", input$patient_id,
                         if (identical(res$source, "api")) "via web service" else "saved locally, API unreachable"))
    }
  })

  output$status_msg <- renderText(status_rv())

  output$report_tabs_ui <- renderUI({
    rep <- report_rv()
    if (is.null(rep) || length(rep) == 0) return(p("Upload a subject's stats files and click 'Process & preview'."))
    do.call(tabsetPanel, lapply(names(rep), function(key) {
      tabPanel(fmt_key(key), DTOutput(paste0("dt_", key)))
    }))
  })

  observe({
    rep <- report_rv()
    req(rep)
    for (key in names(rep)) {
      local({
        k <- key
        output[[paste0("dt_", k)]] <- renderDT({
          df <- rep[[k]]
          if (nrow(df) == 0) return(datatable(data.frame(Message = "No reference model available for this region.")))
          datatable(df, rownames = FALSE, options = list(pageLength = 15)) |>
            formatStyle("out_of_range", target = "row",
                        backgroundColor = styleEqual(c(TRUE, FALSE), c("#fde0e0", "white")))
        })
      })
    }
  })

  # ---- CDISC preview tables ----
  cdisc_rv <- reactive({
    rep <- report_rv()
    req(rep)
    build_cdisc(rep, input$patient_id, input$age,
                sex = if (nzchar(input$sex)) input$sex else NA)
  })

  output$sdtm_table <- renderDT({
    cd <- cdisc_rv()
    validate(need(nrow(cd$sdtm) > 0, "No SDTM data - process a subject first."))
    datatable(cd$sdtm, rownames = FALSE, options = list(pageLength = 20, scrollX = TRUE))
  })

  output$adam_table <- renderDT({
    cd <- cdisc_rv()
    validate(need(nrow(cd$adam) > 0, "No ADaM data - process a subject first."))
    datatable(cd$adam, rownames = FALSE, options = list(pageLength = 20, scrollX = TRUE)) |>
      formatStyle("ANRIND", target = "row",
                  backgroundColor = styleEqual(c("LOW", "HIGH", "NORMAL"),
                                                c("#fde0e0", "#fde0e0", "white")))
  })

  output$download_pdf <- downloadHandler(
    filename = function() paste0("neuroimaging_report_", input$patient_id, ".pdf"),
    content = function(file) {
      rep <- report_rv()
      validate(need(!is.null(rep), "Process a subject first."))
      patient <- list(patient_id = input$patient_id,
                       display_name = if (nzchar(input$display_name)) input$display_name else input$patient_id,
                       age = input$age,
                       sex = if (nzchar(input$sex)) input$sex else NA,
                       notes = input$notes)
      generate_pdf_report(rep, patient, cdisc = cdisc_rv(), output_path = file)
    }
  )

  observeEvent(input$plot_key, {
    subj <- stats_rv()
    req(subj, input$plot_key %in% names(subj))
    updateSelectInput(session, "plot_column", choices = names(subj[[input$plot_key]]))
  })

  output$region_plot <- renderPlot({
    req(stats_rv(), input$plot_key, input$plot_column)
    key <- input$plot_key
    parts <- strsplit(key, "_")[[1]]
    region <- parts[1]; metric <- paste(parts[-1], collapse = "_")
    grp <- age_group_for(input$age)
    region_metric <- paste(region, metric, sep = "_")

    model_entry <- models_rv()[[region_metric]][[grp]][[input$plot_column]]
    validate(need(!is.null(model_entry), "No reference model available for this region / age group."))

    demo <- load_reference_demographics(REFERENCE_DIR)
    long_df <- build_reference_long(REFERENCE_DIR, region, metric, demo)
    long_df <- long_df[vapply(long_df$age, function(a) age_group_for(a) == grp, logical(1)), ]

    patient_value <- stats_rv()[[key]][[input$plot_column]]
    plot_reference_scatter(long_df, input$plot_column, model_entry$model,
                            input$age, patient_value,
                            unit = METRIC_UNITS[[metric]] %||% "", title = fmt_key(key))
  })

  # ---- Patient Database tab ----

  patients_rv <- reactiveVal(data.frame())

  refresh_patients <- function() {
    con <- db_connect(DB_PATH)
    on.exit(DBI::dbDisconnect(con))
    patients_rv(db_list_patients(con))
  }
  observeEvent(input$refresh_db_btn, refresh_patients())
  observeEvent(input$save_btn, refresh_patients())
  observe({ refresh_patients() })

  output$patients_table <- renderDT({
    datatable(patients_rv(), selection = "single", rownames = FALSE)
  })

  output$selected_pdf_ui <- renderUI({
    sel <- input$patients_table_rows_selected
    req(sel)
    downloadButton("download_saved_pdf", "Download this patient's PDF (SDTM + ADaM)", class = "btn-info")
  })

  output$download_saved_pdf <- downloadHandler(
    filename = function() {
      sel <- input$patients_table_rows_selected
      pid <- patients_rv()[sel, "patient_id"]
      paste0("neuroimaging_report_", pid, ".pdf")
    },
    content = function(file) {
      sel <- input$patients_table_rows_selected
      row <- patients_rv()[sel, ]
      con <- db_connect(DB_PATH)
      on.exit(DBI::dbDisconnect(con))
      rep <- db_get_report(con, row$patient_id)
      patient <- list(patient_id = row$patient_id, display_name = row$display_name,
                       age = row$age, sex = row$sex, notes = row$notes)
      generate_pdf_report(rep, patient, output_path = file)
    }
  )

  output$selected_report_ui <- renderUI({
    sel <- input$patients_table_rows_selected
    req(sel)
    pid <- patients_rv()[sel, "patient_id"]
    con <- db_connect(DB_PATH)
    on.exit(DBI::dbDisconnect(con))
    rep <- db_get_report(con, pid)
    if (length(rep) == 0) return(p("No saved report for this patient."))
    do.call(tabsetPanel, lapply(names(rep), function(key) {
      tabPanel(fmt_key(key), renderDT({
        datatable(rep[[key]], rownames = FALSE) |>
          formatStyle("out_of_range", target = "row",
                      backgroundColor = styleEqual(c(TRUE, FALSE), c("#fde0e0", "white")))
      }))
    }))
  })

  # ---- FreeSurfer tab ----

  fs_status_rv <- reactiveVal(NULL)
  refresh_fs_status <- function() {
    fs_status_rv(freesurfer_status())
    subs <- list_freesurfer_subjects()
    updateSelectInput(session, "fs_existing_subject", choices = subs)
    updateSelectInput(session, "qc_subject", choices = subs, selected = isolate(input$qc_subject))
  }
  observeEvent(input$fs_status_btn, refresh_fs_status(), ignoreNULL = FALSE)

  output$fs_status <- renderText({
    st <- fs_status_rv()
    req(st)
    yn <- function(x) if (isTRUE(x) || (is.character(x) && nzchar(x))) "yes" else "no"
    paste0(
      "Ready to run:      ", yn(st$ready), "\n",
      "OS:                ", st$os %||% "?", "\n",
      "FreeSurfer:        ", st$freesurfer_version %||% "not installed", "\n",
      "License:           ", yn(st$license_file), "\n",
      "MATLAB runtime:    ", yn(st$matlab_runtime), "  (hippocampus/brainstem)\n",
      "dcm2niix:          ", yn(st$dcm2niix), "\n",
      "SUBJECTS_DIR:      ", st$subjects_dir %||% "?")
  })

  fs_start_rv <- reactiveVal("")
  output$fs_start_msg <- renderText(fs_start_rv())
  observeEvent(input$fs_start_btn, {
    req(input$fs_patient_id)
    res <- tryCatch({
      dicom <- if (input$fs_input_mode == "zip") {
        if (is.null(input$fs_dicom_zip)) stop("choose a DICOM .zip first")
        stage_dicom_zip(input$fs_dicom_zip$datapath, input$fs_patient_id)
      } else input$fs_dicom_path
      start_pipeline_job(input$fs_patient_id, dicom_dir = dicom,
                         age = if (is.na(input$fs_age)) NULL else input$fs_age,
                         sex = input$fs_sex, threads = input$fs_threads,
                         subregions = input$fs_subregions)
    }, error = function(e) e)
    if (inherits(res, "error")) fs_start_rv(paste("Could not start:", conditionMessage(res)))
    else fs_start_rv(sprintf("Started job %s", res$job_id))
    fs_jobs_tick(fs_jobs_tick() + 1)
  })

  fs_jobs_tick <- reactiveVal(0)
  observeEvent(input$fs_jobs_refresh, fs_jobs_tick(fs_jobs_tick() + 1))
  fs_jobs <- reactive({
    fs_jobs_tick()
    invalidateLater(15000)
    list_pipeline_jobs()
  })
  output$fs_jobs_table <- renderDT({
    datatable(fs_jobs(), selection = "single", rownames = FALSE, options = list(pageLength = 8)) |>
      formatStyle("status", target = "row",
                  backgroundColor = styleEqual(c("failed", "succeeded"), c("#fde0e0", "#e3f4e1")))
  })
  output$fs_job_log <- renderText({
    sel <- input$fs_jobs_table_rows_selected
    jobs <- fs_jobs()
    req(sel, nrow(jobs) >= sel)
    j <- get_pipeline_job(jobs$job_id[sel], tail_lines = 60)
    paste(c(sprintf("[%s] %s", j$status, j$current_step), "", j$log_tail), collapse = "\n")
  })

  # MNE visual QC
  qc_tick <- reactiveVal(0)
  qc_msg_rv <- reactiveVal("")
  output$qc_msg <- renderText(qc_msg_rv())
  observeEvent(input$qc_generate_btn, {
    req(input$qc_subject)
    withProgress(message = "Rendering with MNE-Python...", value = 0.3, {
      r <- tryCatch(run_mne_visualization(input$qc_subject, three_d = input$qc_3d),
                    error = function(e) list(ok = FALSE, output = conditionMessage(e)))
    })
    qc_msg_rv(if (isTRUE(r$ok)) utils::tail(r$output, 1) else paste(utils::tail(r$output, 6), collapse = "\n"))
    qc_tick(qc_tick() + 1)
  })
  qc_pngs <- reactive({
    qc_tick(); fs_jobs()
    req(input$qc_subject)
    f <- list_qc_files(input$qc_subject)
    f[grepl("\\.png$", f)]
  })
  output$qc_images_ui <- renderUI({
    f <- qc_pngs()
    if (!length(f)) return(p(em("No MNE figures yet for this subject - click 'Generate / refresh'.")))
    # 3D view first, then the slice panels
    f <- f[order(!grepl("3d", f))]
    tagList(lapply(seq_along(f), function(i) {
      id <- paste0("qc_img_", i)
      local({
        file <- f[i]
        output[[id]] <- renderImage({
          list(src = qc_file_path(isolate(input$qc_subject), file), contentType = "image/png",
               style = "max-width:100%; height:auto;", alt = file)
        }, deleteFile = FALSE)
      })
      div(style = "margin-bottom:12px", imageOutput(id, height = "auto"))
    }))
  })
  output$qc_html_dl <- downloadHandler(
    filename = function() paste0(input$qc_subject, "_mne_report.html"),
    content = function(file) {
      p <- qc_file_path(input$qc_subject, "mne_report.html")
      if (is.null(p)) stop("No MNE report yet - generate it first")
      file.copy(p, file)
    })

  observeEvent(input$fs_load_btn, {
    req(input$fs_existing_subject)
    subj <- tryCatch(read_processed_subject(input$fs_existing_subject), error = function(e) e)
    if (inherits(subj, "error")) {
      showNotification(conditionMessage(subj), type = "error")
      return(invisible())
    }
    updateTextInput(session, "patient_id", value = input$fs_existing_subject)
    updateNumericInput(session, "age", value = input$fs_existing_age)
    updateSelectInput(session, "sex", selected = input$fs_existing_sex)
    stats_rv(subj)
    report_rv(build_full_report(subj, input$fs_existing_age, models_rv(), NAMES_DIR))
    updateSelectInput(session, "plot_key", choices = names(subj))
    status_rv(sprintf("Loaded %s from SUBJECTS_DIR (%d tables). Review, then 'Save to database'.",
                      input$fs_existing_subject, length(subj)))
    updateNavbarPage(session, "main_nav", selected = "New Patient")
  })

  # ---- Reference Models tab ----

  cohort_tick <- reactiveVal(0)
  output$cohort_table <- renderDT({
    cohort_tick()
    s <- reference_summary(REFERENCE_DIR)$summary
    validate(need(nrow(s) > 0, "No stats tables found in the reference folder."))
    datatable(s, rownames = FALSE, options = list(dom = "t")) |>
      formatStyle("without_age_ignored", backgroundColor = styleInterval(0, c("white", "#fde0e0")))
  })

  observeEvent(input$rebuild_btn, {
    cohort_tick(cohort_tick() + 1)
    log_lines <- character()
    withProgress(message = "Rebuilding reference models", value = 0, {
      res <- build_reference_models(REFERENCE_DIR, MODELS_PATH,
                                     progress = function(m) {
                                       log_lines <<- c(log_lines, m)
                                       incProgress(1 / 12, detail = m)
                                     })
      models_rv(res$models)
      output$rebuild_log <- renderText(paste(log_lines, collapse = "\n"))
      output$fit_summary_table <- renderDT(datatable(res$fit_log, rownames = FALSE))
    })
  })
}

shinyApp(ui, server)
