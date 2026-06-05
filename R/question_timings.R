#' Compute per-question response times from event data
#'
#' For each respondent-page-question combination, estimates the time spent
#' (`time_on_q`) by measuring the gap between the answer event and the most
#' recent preceding "start" event.  The start is taken as the later of:
#' * the previous answer on the same page, or
#' * the page load time,
#' adjusted forward to the last focus/visibility event before the answer.
#'
#' @param events A data frame returned by [parse_timing()].
#'
#' @return A [tibble][tibble::tibble-package] with one row per
#'   respondent-page-question and columns:
#'   \describe{
#'     \item{respondent}{Respondent identifier.}
#'     \item{page_index}{Zero-based page index.}
#'     \item{qid}{Question identifier (e.g. `"QID1"`).}
#'     \item{answer_time}{Timestamp of the first answer event for this question.}
#'     \item{last_event}{Timestamp of the last event for this question.}
#'     \item{n_events}{Number of events recorded for this question.}
#'     \item{time_on_q}{Estimated seconds spent on this question.}
#'   }
#' @export
#'
#' @examples
#' \dontrun{
#' raw <- read_qualtrics("survey_data.csv")
#' events <- parse_timing(raw)
#' qtimes <- question_timings(events)
#' }
question_timings <- function(events) {
  answers <- events |>
    dplyr::filter(!is.na(name)) |>
    dplyr::group_by(respondent, page_index, name) |>
    dplyr::summarise(
      answer_time = min(time),
      last_event = max(time),
      n_events = dplyr::n(),
      load_time = dplyr::first(load_time),
      .groups = "drop"
    ) |>
    dplyr::arrange(respondent, page_index, answer_time) |>
    dplyr::group_by(respondent, page_index) |>
    dplyr::mutate(prev_answer_time = dplyr::lag(answer_time)) |>
    dplyr::ungroup()

  focus_events <- events |>
    dplyr::filter(type %in% c("window_focus", "visible")) |>
    dplyr::select(respondent, page_index, focus_time = time) |>
    dplyr::mutate(focus_time_num = as.numeric(focus_time)) |>
    dplyr::arrange(respondent, page_index, focus_time)

  start_times_num <- vapply(seq_len(nrow(answers)), function(i) {
    curr <- answers[i, ]

    start_min_num <- if (!is.na(curr$prev_answer_time)) {
      as.numeric(curr$prev_answer_time)
    } else {
      as.numeric(curr$load_time)
    }

    valid <- focus_events |>
      dplyr::filter(
        respondent == curr$respondent,
        page_index == curr$page_index,
        focus_time_num >= start_min_num,
        focus_time_num < as.numeric(curr$answer_time)
      )

    if (nrow(valid) > 0) {
      max(valid$focus_time_num)
    } else {
      start_min_num
    }
  }, numeric(1))

  answers |>
    dplyr::mutate(
      start_time = as.POSIXct(start_times_num, origin = "1970-01-01"),
      time_on_q = as.numeric(difftime(answer_time, start_time, units = "secs"))
    ) |>
    dplyr::rename(qid = name) |>
    dplyr::select(
      respondent,
      page_index,
      qid,
      answer_time,
      last_event,
      n_events,
      time_on_q
    )
}
