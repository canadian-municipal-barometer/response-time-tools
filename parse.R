library(jsonlite)
library(dplyr)
library(tidyr)
library(purrr)
library(lubridate)
library(ggplot2)
library(readr)

# ---- 1. Load Qualtrics CSV ----
# Qualtrics exports have a header row plus 2 metadata rows. Keep the header,
# skip the metadata.
read_qualtrics <- function(path) {
  hdr <- read_csv(path, n_max = 0, show_col_types = FALSE)
  df <- read_csv(path, skip = 3, col_names = names(hdr), show_col_types = FALSE)
  # rename for easier reference
  df |> rename("timing" = "__js_timing")
}

# ---- 2. Flatten the `timing` JSON into a long event table ----
parse_timing <- function(df, id_col = "ResponseId", timing_col = "timing") {
  safe_parse <- possibly(
    ~ fromJSON(.x, simplifyVector = FALSE),
    otherwise = NULL
  )

  df |>
    transmute(
      respondent = .data[[id_col]],
      parsed = map(.data[[timing_col]], safe_parse)
    ) |>
    filter(!map_lgl(parsed, is.null)) |> # nolint
    mutate(pages = map(parsed, "pages")) |>
    select(respondent, pages) |> # nolint
    unnest_longer(pages) |>
    mutate(
      page_index = map_int(pages, ~ .x$page_index %||% NA_integer_),
      load_time = map_chr(pages, ~ .x$load_time %||% NA_character_),
      submit_time = map_chr(pages, ~ .x$submit_time %||% NA_character_),
      events = map(pages, "events")
    ) |>
    select(-pages) |>
    unnest_longer(events) |>
    mutate(
      type = map_chr(events, ~ .x$type %||% NA_character_),
      time = map_chr(events, ~ .x$time %||% NA_character_),
      input_type = map_chr(events, ~ .x$input_type %||% NA_character_),
      name = map_chr(events, ~ .x$name %||% NA_character_)
    ) |>
    select(-events) |>
    mutate(
      load_time = ymd_hms(load_time), # nolint
      submit_time = ymd_hms(submit_time), # nolint
      time = ymd_hms(time),
      t_since_load = as.numeric(difftime(time, load_time, units = "secs"))
    )
}

# ---- 3. Per-question approximation ----
# time_on_q = time from previous answer (or last focus event, or page load) to
# this answer.
question_timings <- function(events) {
  # Get answer events
  answers <- events |>
    filter(!is.na(name)) |> # nolint
    group_by(respondent, page_index, name) |> # nolint
    summarise(
      answer_time = min(time),
      last_event = max(time),
      n_events = n(),
      load_time = first(load_time), # nolint
      .groups = "drop"
    ) |>
    arrange(respondent, page_index, answer_time) |> # nolint
    group_by(respondent, page_index) |>
    mutate(
      prev_answer_time = lag(answer_time)
    ) |>
    ungroup()

  # Get focus events (window_focus and visible)
  focus_events <- events |>
    filter(type %in% c("window_focus", "visible")) |> # nolint
    select(respondent, page_index, focus_time = time) |> # nolint
    mutate(focus_time_num = as.numeric(focus_time)) |> # nolint
    arrange(respondent, page_index, focus_time)

  # For each answer, find the last focus event after the start point and before
  # the answer
  start_times_num <- sapply(seq_along(nrow(answers)), function(i) {
    # nolint
    curr <- answers[i, ]

    # Start from the later of previous answer or page load
    start_min_num <- if (!is.na(curr$prev_answer_time)) {
      as.numeric(curr$prev_answer_time)
    } else {
      as.numeric(curr$load_time)
    }

    # Find focus events after start_min and before answer_time
    valid <- focus_events |>
      filter(
        respondent == curr$respondent, # nolint
        page_index == curr$page_index, # nolint
        focus_time_num >= start_min_num, # nolint
        focus_time_num < as.numeric(curr$answer_time)
      )

    if (nrow(valid) > 0) {
      # Use the last focus event as start time
      max(valid$focus_time_num)
    } else {
      # No focus event, use start_min
      start_min_num
    }
  })

  answers |>
    mutate(
      start_time = as.POSIXct(start_times_num, origin = "1970-01-01"),
      time_on_q = as.numeric(difftime(answer_time, start_time, units = "secs")) # nolint
    ) |>
    rename(qid = name) |> # nolint
    select(
      respondent, # nolint
      page_index, # nolint
      qid, # nolint
      answer_time, # nolint
      last_event, # nolint
      n_events, # nolint
      time_on_q # nolint
    )
}

# ---- Usage ----
raw <- read_qualtrics("survey_data.csv")
events <- parse_timing(raw)
qtimes <- question_timings(events)

# ---- 5. Wide response-level table: one row per response, one column per
# question time ----
response_q_times <- qtimes |>
  # Align sub-question IDs with Qualtrics ImportIds (e.g., QID2-1 → QID2_1)
  mutate(qid = gsub("-", "_", qid)) |>
  select(respondent, qid, time_on_q) |>
  pivot_wider(
    names_from = qid,
    values_from = time_on_q,
    names_prefix = "time_"
  )

# Preview the new table
cat("New response-level question timing table:\n")
print(response_q_times |> head())

plot_event_density(events)
plot_respondent_timeline(events, n = 25, page = 0)
plot_page_duration(events)
