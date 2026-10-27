#' Interactive explorer for question timing data
#'
#' Launches a Shiny app that visualises the output of [question_timings()].
#' The app has two views:
#' * a wide, horizontally scrollable bar chart of response time per question
#'   (toggleable to per page), filterable from a single respondent up to the
#'   whole dataset, and
#' * a distribution view for one selected question, with variance and central
#'   tendency statistics.
#'
#' @param timings A data frame returned by [question_timings()].
#' @param events Optional data frame returned by [parse_timing()].  When
#'   supplied, the page view can measure page duration as page load to page
#'   submit instead of the sum of its question times.
#' @param labels Optional data frame with columns `qid` and `label`, used to
#'   give questions readable names (e.g. from
#'   `qualtRics::extract_colmap()`).
#' @param ... Passed to [shiny::shinyApp()], e.g. `options = list(port = 8080)`.
#'
#' @return A [shiny::shinyApp()] object; printed at the console it starts the
#'   app.
#' @export
#'
#' @examples
#' \dontrun{
#' raw <- read_qualtrics("survey_data.csv")
#' events <- parse_timing(raw)
#' timing_app(question_timings(events), events = events)
#' }
timing_app <- function(timings, events = NULL, labels = NULL, ...) {
  for (pkg in c("shiny", "bslib", "plotly")) {
    if (!requireNamespace(pkg, quietly = TRUE)) {
      stop("Package '", pkg, "' is required to run timing_app().", call. = FALSE)
    }
  }

  stopifnot(is.data.frame(timings))
  needed <- c("respondent", "page_index", "qid", "time_on_q")
  missing_cols <- setdiff(needed, names(timings))
  if (length(missing_cols)) {
    stop(
      "`timings` is missing column(s): ", paste(missing_cols, collapse = ", "),
      ". Did you pass the output of question_timings()?",
      call. = FALSE
    )
  }

  timings <- as.data.frame(timings)
  timings$qid <- as.character(timings$qid)
  timings$respondent <- as.character(timings$respondent)

  q_levels <- question_order(timings)
  q_labels <- question_labels(q_levels, labels)
  page_levels <- sort(unique(timings$page_index))
  respondents <- sort(unique(timings$respondent))
  has_wall <- !is.null(events) &&
    all(c("respondent", "page_index", "load_time", "submit_time") %in% names(events))

  shiny::shinyApp(
    ui = timing_app_ui(
      respondents = respondents,
      page_levels = page_levels,
      q_levels = q_levels,
      q_labels = q_labels,
      time_range = range(timings$time_on_q, na.rm = TRUE),
      has_wall = has_wall
    ),
    server = timing_app_server(
      timings = timings,
      events = events,
      q_levels = q_levels,
      q_labels = q_labels,
      has_wall = has_wall
    ),
    ...
  )
}

# ---- data helpers ------------------------------------------------------

# Survey order of the questions: by page, then by the typical position of the
# answer within that page.
question_order <- function(timings) {
  timings |>
    dplyr::group_by(.data$respondent, .data$page_index) |>
    dplyr::mutate(
      pos = rank(.data$answer_time, ties.method = "first", na.last = "keep")
    ) |>
    dplyr::group_by(.data$qid) |>
    dplyr::summarise(
      page_index = min(.data$page_index),
      pos = stats::median(.data$pos, na.rm = TRUE),
      .groups = "drop"
    ) |>
    dplyr::arrange(.data$page_index, .data$pos, .data$qid) |>
    dplyr::pull("qid")
}

question_labels <- function(q_levels, labels) {
  out <- stats::setNames(q_levels, q_levels)
  if (is.null(labels)) {
    return(out)
  }
  if (!all(c("qid", "label") %in% names(labels))) {
    warning("`labels` needs columns `qid` and `label`; ignoring it.", call. = FALSE)
    return(out)
  }
  hit <- match(q_levels, as.character(labels$qid))
  lab <- as.character(labels$label)[hit]
  lab <- ifelse(is.na(lab) | !nzchar(lab), q_levels, paste0(q_levels, " - ", lab))
  stats::setNames(lab, q_levels)
}

# Per respondent-page durations, either summed from the question times or
# measured from page load to page submit.
page_durations <- function(timings, events, source) {
  if (identical(source, "wall") && !is.null(events)) {
    events |>
      dplyr::filter(!is.na(.data$submit_time), !is.na(.data$load_time)) |>
      dplyr::distinct(.data$respondent, .data$page_index, .data$load_time, .data$submit_time) |>
      dplyr::mutate(
        respondent = as.character(.data$respondent),
        value = as.numeric(difftime(.data$submit_time, .data$load_time, units = "secs"))
      ) |>
      dplyr::select("respondent", "page_index", "value")
  } else {
    timings |>
      dplyr::group_by(.data$respondent, .data$page_index) |>
      dplyr::summarise(value = sum(.data$time_on_q, na.rm = TRUE), .groups = "drop")
  }
}

# One row per bar: the chosen statistic plus a spread interval.
summarise_units <- function(df, statistic, spread) {
  out <- df |>
    dplyr::group_by(.data$unit) |>
    dplyr::summarise(
      n = sum(!is.na(.data$value)),
      mean = mean(.data$value, na.rm = TRUE),
      median = stats::median(.data$value, na.rm = TRUE),
      sd = stats::sd(.data$value, na.rm = TRUE),
      q25 = stats::quantile(.data$value, 0.25, na.rm = TRUE, names = FALSE),
      q75 = stats::quantile(.data$value, 0.75, na.rm = TRUE, names = FALSE),
      .groups = "drop"
    )

  out$stat <- if (identical(statistic, "median")) out$median else out$mean

  if (identical(spread, "none") || nrow(out) == 0) {
    out$lo <- NA_real_
    out$hi <- NA_real_
  } else if (identical(spread, "iqr")) {
    out$lo <- out$q25
    out$hi <- out$q75
  } else {
    out$lo <- pmax(0, out$stat - out$sd)
    out$hi <- out$stat + out$sd
  }
  out
}

describe_times <- function(x) {
  x <- x[!is.na(x)]
  n <- length(x)
  if (n == 0) {
    return(NULL)
  }
  m <- mean(x)
  s <- stats::sd(x)
  q <- stats::quantile(x, c(0.25, 0.5, 0.75, 0.9), names = FALSE)
  list(
    n = n,
    mean = m,
    median = q[2],
    sd = s,
    var = if (n > 1) stats::var(x) else NA_real_,
    iqr = q[3] - q[1],
    mad = stats::mad(x),
    cv = if (is.finite(s) && m > 0) s / m else NA_real_,
    min = min(x),
    q25 = q[1],
    q75 = q[3],
    p90 = q[4],
    max = max(x),
    skew = if (n > 2 && is.finite(s) && s > 0) sum(((x - m) / s)^3) / n else NA_real_
  )
}

fmt_secs <- function(x, digits = 2) {
  ifelse(is.na(x), "-", formatC(x, format = "f", digits = digits))
}

# ---- palette -----------------------------------------------------------

# Validated categorical slots 1 and 2 (blue, orange) from the reference
# palette; one series per chart, so no legend is needed.
timing_pal <- list(
  bar = "#2a78d6",
  accent = "#eb6834",
  point = "rgba(11,11,11,0.45)",
  grid = "#e7e6e2",
  ink = "#0b0b0b",
  ink_muted = "#52514e",
  surface = "#fcfcfb"
)

plotly_base <- function(p, xtitle, ytitle) {
  plotly::layout(
    p,
    paper_bgcolor = timing_pal$surface,
    plot_bgcolor = timing_pal$surface,
    font = list(color = timing_pal$ink, size = 12),
    hoverlabel = list(font = list(size = 12)),
    bargap = 0.35,
    xaxis = list(
      title = list(text = xtitle, font = list(color = timing_pal$ink_muted)),
      tickfont = list(color = timing_pal$ink_muted),
      showgrid = FALSE,
      zeroline = FALSE,
      fixedrange = TRUE
    ),
    yaxis = list(
      title = list(text = ytitle, font = list(color = timing_pal$ink_muted)),
      tickfont = list(color = timing_pal$ink_muted),
      gridcolor = timing_pal$grid,
      zeroline = FALSE,
      rangemode = "tozero"
    ),
    margin = list(l = 60, r = 20, t = 10, b = 130)
  ) |>
    plotly::config(displayModeBar = FALSE)
}

# ---- ui ----------------------------------------------------------------

timing_app_ui <- function(respondents, page_levels, q_levels, q_labels,
                          time_range, has_wall) {
  page_choices <- stats::setNames(page_levels, paste("Page", page_levels))
  q_choices <- stats::setNames(q_levels, unname(q_labels))

  bslib::page_sidebar(
    title = "Survey response timing",
    theme = bslib::bs_theme(version = 5, primary = timing_pal$bar),
    sidebar = bslib::sidebar(
      width = 320,
      shiny::tags$style(shiny::HTML(
        ".selectize-input { max-height: 150px; overflow-y: auto; }"
      )),
      shiny::h6("Filter the data"),
      shiny::selectizeInput(
        "respondents", "Respondents",
        choices = respondents, selected = respondents, multiple = TRUE,
        options = list(plugins = list("remove_button"), maxItems = NULL)
      ),
      shiny::div(
        class = "d-flex gap-2 mb-3",
        shiny::actionButton("all_resp", "All", class = "btn-sm btn-outline-secondary"),
        shiny::actionButton("no_resp", "Clear", class = "btn-sm btn-outline-secondary"),
        shiny::actionButton("rand_resp", "Random one", class = "btn-sm btn-outline-secondary")
      ),
      shiny::selectizeInput(
        "pages", "Pages",
        choices = page_choices, selected = page_levels, multiple = TRUE,
        options = list(plugins = list("remove_button"))
      ),
      shiny::selectizeInput(
        "questions", "Questions",
        choices = q_choices, selected = q_levels, multiple = TRUE,
        options = list(plugins = list("remove_button"))
      ),
      shiny::sliderInput(
        "time_range", "Time on question (s)",
        min = floor(time_range[1]), max = ceiling(time_range[2]),
        value = c(floor(time_range[1]), ceiling(time_range[2])), step = 0.5
      ),
      shiny::hr(),
      shiny::h6("Summarise"),
      shiny::radioButtons(
        "statistic", "Statistic across respondents",
        choices = c("Median" = "median", "Mean" = "mean"), selected = "median",
        inline = TRUE
      ),
      shiny::radioButtons(
        "spread", "Interval",
        choices = c("IQR" = "iqr", "SD" = "sd", "None" = "none"),
        selected = "iqr", inline = TRUE
      ),
      shiny::checkboxInput("show_points", "Overlay individual responses", TRUE),
      shiny::sliderInput("bar_px", "Bar spacing (px)", min = 16, max = 140, value = 46, step = 2)
    ),
    bslib::navset_card_tab(
      id = "tabs",
      bslib::nav_panel(
        "Timeline",
        shiny::div(
          class = "d-flex flex-wrap align-items-center gap-3 mb-2",
          shiny::radioButtons(
            "granularity", NULL,
            choices = c("Per question" = "question", "Per page" = "page"),
            selected = "question", inline = TRUE
          ),
          if (has_wall) {
            shiny::conditionalPanel(
              "input.granularity == 'page'",
              shiny::radioButtons(
                "page_source", NULL,
                choices = c(
                  "Sum of question times" = "sum",
                  "Page load to submit" = "wall"
                ),
                selected = "sum", inline = TRUE
              )
            )
          },
          shiny::div(class = "ms-auto text-muted small", shiny::textOutput("scope", inline = TRUE))
        ),
        shiny::div(
          style = paste(
            "overflow-x:auto; overflow-y:hidden; width:100%;",
            "border:1px solid", timing_pal$grid, "; border-radius:6px;"
          ),
          shiny::uiOutput("timeline_ui")
        ),
        shiny::p(
          class = "text-muted small mt-2 mb-0",
          "Questions are in survey order (page, then answer order). Scroll",
          "horizontally to walk the survey; click a bar to load it in the",
          "Distribution tab."
        )
      ),
      bslib::nav_panel(
        "Distribution",
        shiny::div(
          class = "d-flex flex-wrap align-items-end gap-3 mb-3",
          shiny::selectInput("dist_q", "Question", choices = q_choices, width = "420px"),
          shiny::sliderInput("bins", "Bins", min = 5, max = 60, value = 20, width = "220px")
        ),
        shiny::uiOutput("stat_tiles"),
        bslib::layout_columns(
          col_widths = c(8, 4),
          bslib::card(
            bslib::card_header("Distribution of response times"),
            plotly::plotlyOutput("hist", height = "340px")
          ),
          bslib::card(
            bslib::card_header("Spread"),
            plotly::plotlyOutput("box", height = "340px")
          )
        ),
        bslib::card(
          bslib::card_header("Statistics"),
          shiny::tableOutput("stat_table")
        )
      )
    )
  )
}

# ---- server ------------------------------------------------------------

timing_app_server <- function(timings, events, q_levels, q_labels, has_wall) {
  function(input, output, session) {
    respondents <- sort(unique(timings$respondent))

    shiny::observeEvent(input$all_resp, {
      shiny::updateSelectizeInput(session, "respondents", selected = respondents)
    })
    shiny::observeEvent(input$no_resp, {
      shiny::updateSelectizeInput(session, "respondents", selected = character(0))
    })
    shiny::observeEvent(input$rand_resp, {
      shiny::updateSelectizeInput(session, "respondents", selected = sample(respondents, 1))
    })

    filtered <- shiny::reactive({
      rng <- input$time_range %||% c(-Inf, Inf)
      timings |>
        dplyr::filter(
          .data$respondent %in% (input$respondents %||% character(0)),
          .data$page_index %in% as.integer(input$pages %||% integer(0)),
          .data$qid %in% (input$questions %||% character(0)),
          !is.na(.data$time_on_q),
          .data$time_on_q >= rng[1],
          .data$time_on_q <= rng[2]
        )
    })

    # Long data for the timeline: one row per respondent per unit (question or
    # page), depending on the granularity toggle.
    unit_data <- shiny::reactive({
      df <- filtered()
      if (identical(input$granularity, "page")) {
        src <- if (has_wall) input$page_source %||% "sum" else "sum"
        pages <- page_durations(df, events, src)
        if (identical(src, "wall")) {
          pages <- dplyr::filter(
            pages,
            .data$respondent %in% (input$respondents %||% character(0)),
            .data$page_index %in% as.integer(input$pages %||% integer(0))
          )
        }
        lv <- sort(unique(pages$page_index))
        pages |>
          dplyr::mutate(unit = factor(paste("Page", .data$page_index),
            levels = paste("Page", lv)
          )) |>
          dplyr::select("respondent", "unit", "value")
      } else {
        lv <- q_levels[q_levels %in% df$qid]
        df |>
          dplyr::mutate(unit = factor(unname(q_labels[.data$qid]),
            levels = unname(q_labels[lv])
          )) |>
          dplyr::select("respondent", "unit", value = "time_on_q")
      }
    })

    unit_summary <- shiny::reactive({
      df <- unit_data()
      if (nrow(df) == 0) {
        return(df[0, ])
      }
      out <- summarise_units(df, input$statistic, input$spread)
      out[order(match(as.character(out$unit), levels(df$unit))), ]
    })

    output$scope <- shiny::renderText({
      n_r <- length(unique(unit_data()$respondent))
      n_u <- nrow(unit_summary())
      paste0(
        n_r, if (n_r == 1) " respondent" else " respondents", " | ",
        n_u, if (identical(input$granularity, "page")) " pages" else " questions"
      )
    })

    timeline_width <- shiny::reactive({
      n <- max(nrow(unit_summary()), 1)
      max(760, 90 + n * (input$bar_px %||% 46))
    })

    output$timeline_ui <- shiny::renderUI({
      plotly::plotlyOutput(
        "timeline",
        height = "460px", width = paste0(timeline_width(), "px")
      )
    })

    output$timeline <- plotly::renderPlotly({
      s <- unit_summary()
      shiny::validate(shiny::need(nrow(s) > 0, "No data for the current filters."))
      raw <- unit_data()
      single <- length(unique(raw$respondent)) <= 1
      stat_name <- if (single) "Time" else if (identical(input$statistic, "median")) "Median" else "Mean"

      err <- if (!single && !all(is.na(s$lo))) {
        list(
          type = "data",
          symmetric = FALSE,
          array = s$hi - s$stat,
          arrayminus = s$stat - s$lo,
          color = timing_pal$ink_muted,
          thickness = 1.5,
          width = 3
        )
      } else {
        NULL
      }

      hover <- paste0(
        "<b>", s$unit, "</b><br>",
        stat_name, ": ", fmt_secs(s$stat), " s<br>",
        "n = ", s$n,
        ifelse(single, "",
          paste0(
            "<br>IQR: ", fmt_secs(s$q25), "-", fmt_secs(s$q75), " s",
            "<br>SD: ", fmt_secs(s$sd), " s"
          )
        )
      )

      p <- plotly::plot_ly(source = "timeline", width = timeline_width(), height = 460) |>
        plotly::add_bars(
          x = s$unit, y = s$stat,
          marker = list(color = timing_pal$bar),
          error_y = err,
          hovertemplate = paste0(hover, "<extra></extra>"),
          name = stat_name
        )

      if (isTRUE(input$show_points) && !single) {
        p <- plotly::add_markers(
          p,
          x = raw$unit, y = raw$value,
          marker = list(
            size = 7, color = timing_pal$point,
            line = list(width = 1.5, color = timing_pal$surface)
          ),
          text = raw$respondent,
          hovertemplate = "%{text}<br>%{y:.2f} s<extra></extra>",
          name = "responses"
        )
      }

      p |>
        plotly_base(NULL, "Seconds") |>
        plotly::layout(
          showlegend = FALSE,
          xaxis = list(
            tickangle = -45,
            type = "category",
            categoryorder = "array",
            categoryarray = as.character(s$unit),
            fixedrange = TRUE
          )
        ) |>
        plotly::event_register("plotly_click")
    })

    # Clicking a question bar sends you to its distribution.
    shiny::observeEvent(plotly::event_data("plotly_click", source = "timeline"), {
      if (!identical(input$granularity, "question")) {
        return()
      }
      ev <- plotly::event_data("plotly_click", source = "timeline")
      qid <- names(q_labels)[match(ev$x, unname(q_labels))]
      if (length(qid) == 1 && !is.na(qid)) {
        shiny::updateSelectInput(session, "dist_q", selected = qid)
        bslib::nav_select("tabs", "Distribution", session = session)
      }
    })

    dist_values <- shiny::reactive({
      q <- input$dist_q %||% q_levels[1]
      df <- filtered() |> dplyr::filter(.data$qid == q)
      df$time_on_q
    })

    dist_stats <- shiny::reactive(describe_times(dist_values()))

    output$stat_tiles <- shiny::renderUI({
      st <- dist_stats()
      if (is.null(st)) {
        return(shiny::div(class = "text-muted", "No responses for this question under the current filters."))
      }
      tile <- function(label, value, sub = NULL) {
        bslib::value_box(
          title = label,
          value = value,
          showcase = NULL,
          theme = bslib::value_box_theme(bg = timing_pal$surface, fg = timing_pal$ink),
          shiny::span(class = "text-muted small", sub %||% "")
        )
      }
      bslib::layout_columns(
        col_widths = c(3, 3, 3, 3),
        tile("Median", paste0(fmt_secs(st$median), " s"), paste0("IQR ", fmt_secs(st$iqr), " s")),
        tile("Mean", paste0(fmt_secs(st$mean), " s"), paste0("SD ", fmt_secs(st$sd), " s")),
        tile("Variance", fmt_secs(st$var), paste0("CV ", fmt_secs(st$cv))),
        tile("Responses", st$n, paste0("range ", fmt_secs(st$min), "-", fmt_secs(st$max), " s"))
      )
    })

    output$hist <- plotly::renderPlotly({
      x <- dist_values()
      st <- dist_stats()
      shiny::validate(shiny::need(length(x) > 0, "No responses for this question."))
      nb <- input$bins %||% 20
      rng <- range(x)
      size <- if (diff(rng) > 0) diff(rng) / nb else 1

      plotly::plot_ly() |>
        plotly::add_histogram(
          x = x,
          xbins = list(start = rng[1], end = rng[2] + size, size = size),
          marker = list(color = timing_pal$bar, line = list(width = 2, color = timing_pal$surface)),
          hovertemplate = "%{x} s<br>%{y} responses<extra></extra>"
        ) |>
        plotly::layout(shapes = list(list(
          type = "line", xref = "x", yref = "paper",
          x0 = st$median, x1 = st$median, y0 = 0, y1 = 1,
          line = list(color = timing_pal$accent, width = 2, dash = "dash")
        ))) |>
        plotly::add_annotations(
          x = st$median, y = 1, yref = "paper", yanchor = "bottom",
          text = paste0("median ", fmt_secs(st$median), " s"),
          showarrow = FALSE, font = list(color = timing_pal$accent, size = 11)
        ) |>
        plotly_base("Seconds", "Responses") |>
        plotly::layout(
          showlegend = FALSE,
          margin = list(l = 60, r = 20, t = 30, b = 50),
          xaxis = list(fixedrange = FALSE)
        )
    })

    output$box <- plotly::renderPlotly({
      x <- dist_values()
      shiny::validate(shiny::need(length(x) > 0, "No responses for this question."))
      plotly::plot_ly() |>
        plotly::add_boxplot(
          y = x, boxpoints = "all", jitter = 0.5, pointpos = 0,
          fillcolor = "rgba(42,120,214,0.18)",
          line = list(color = timing_pal$bar, width = 2),
          marker = list(size = 8, color = timing_pal$point,
                        line = list(width = 1.5, color = timing_pal$surface)),
          name = "", hovertemplate = "%{y:.2f} s<extra></extra>"
        ) |>
        plotly_base(NULL, "Seconds") |>
        plotly::layout(
          showlegend = FALSE,
          margin = list(l = 60, r = 20, t = 30, b = 40),
          xaxis = list(showticklabels = FALSE)
        )
    })

    output$stat_table <- shiny::renderTable(
      {
        st <- dist_stats()
        shiny::validate(shiny::need(!is.null(st), "No responses for this question."))
        data.frame(
          Statistic = c(
            "n", "Mean", "Median", "Std. deviation", "Variance", "IQR", "MAD",
            "Coef. of variation", "Skewness", "Min", "25th pct", "75th pct",
            "90th pct", "Max"
          ),
          Value = c(
            as.character(st$n), fmt_secs(st$mean), fmt_secs(st$median),
            fmt_secs(st$sd), fmt_secs(st$var), fmt_secs(st$iqr), fmt_secs(st$mad),
            fmt_secs(st$cv), fmt_secs(st$skew), fmt_secs(st$min), fmt_secs(st$q25),
            fmt_secs(st$q75), fmt_secs(st$p90), fmt_secs(st$max)
          ),
          check.names = FALSE
        )
      },
      striped = TRUE, width = "100%", align = "lr"
    )
  }
}
