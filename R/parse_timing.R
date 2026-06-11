#' Flatten Qualtrics timing JSON into a long event table
#'
#' Parses the JSON timing data stored in a column of a Qualtrics export and
#' returns a tidy, row-per-event data frame.  Each event records a page index,
#' load/submit timestamps, event type, timestamp, input element metadata, and
#' seconds elapsed since page load.
#'
#' @importFrom rlang %||% .data
#' @param df A data frame returned by [read_qualtrics()].
#' @param id_col Name of the column that uniquely identifies respondents.
#'   Default `"ResponseId"`.
#' @param timing_col Name of the column containing the raw timing JSON strings.
#'   Default `"timing"`.
#'
#' @return A [tibble][tibble::tibble-package] with columns:
#'   \describe{
#'     \item{respondent}{Respondent identifier.}
#'     \item{page_index}{Zero-based page index.}
#'     \item{load_time}{Page load time (POSIXct).}
#'     \item{submit_time}{Page submit time (POSIXct).}
#'     \item{type}{Event type (e.g., `"change"`, `"click"`, `"window_focus"`).}
#'     \item{time}{Event timestamp (POSIXct).}
#'     \item{input_type}{HTML input type (e.g. `"radio"`, `"textarea"`,
#'       `"select"`).}
#'     \item{name}{Question ID (e.g. `"QID1"`), if associated with an input.}
#'     \item{t_since_load}{Seconds between page load and this event.}
#'   }
#' @export
#'
#' @examples
#' \dontrun{
#' raw <- read_qualtrics("survey_data.csv")
#' events <- parse_timing(raw)
#' }
parse_timing <- function(df, id_col = "ResponseId", timing_col = "timing") {
  safe_parse <- purrr::possibly(
    ~ jsonlite::fromJSON(.x, simplifyVector = FALSE),
    otherwise = NULL
  )

  df |>
    dplyr::transmute(
      respondent = .data[[id_col]],
      parsed = purrr::map(.data[[timing_col]], safe_parse)
    ) |>
    dplyr::filter(!purrr::map_lgl(parsed, is.null)) |>
    dplyr::mutate(pages = purrr::map(parsed, "pages")) |>
    dplyr::select(respondent, pages) |>
    tidyr::unnest_longer(pages) |>
    dplyr::mutate(
      page_index = purrr::map_int(pages, ~ .x$page_index %||% NA_integer_),
      load_time = purrr::map_chr(pages, ~ .x$load_time %||% NA_character_),
      submit_time = purrr::map_chr(pages, ~ .x$submit_time %||% NA_character_),
      events = purrr::map(pages, "events")
    ) |>
    dplyr::select(-pages) |>
    tidyr::unnest_longer(events) |>
    dplyr::mutate(
      type = purrr::map_chr(events, ~ .x$type %||% NA_character_),
      time = purrr::map_chr(events, ~ .x$time %||% NA_character_),
      input_type = purrr::map_chr(events, ~ .x$input_type %||% NA_character_),
      name = purrr::map_chr(events, ~ .x$name %||% NA_character_)
    ) |>
    dplyr::select(-events) |>
    dplyr::mutate(
      load_time = lubridate::ymd_hms(load_time),
      submit_time = lubridate::ymd_hms(submit_time),
      time = lubridate::ymd_hms(time),
      t_since_load = as.numeric(difftime(time, load_time, units = "secs"))
    )
}
