#' Flatten Qualtrics timing JSON into a long event table
#'
#' Parses the JSON timing data stored in a Qualtrics export and returns a tidy,
#' row-per-event data frame.  Each event records a page index, load/submit
#' timestamps, event type, timestamp, input element metadata, and seconds
#' elapsed since page load.
#'
#' The logger spreads long logs across numbered fields (`timing`, `timing_2`,
#' `timing_3`, ...) to stay under Qualtrics' 20,000-byte limit per embedded
#' data value.  Every such column present in `df` is read and the pages are
#' combined.  Both the current compact log format (v2) and the original one
#' (v1) are understood.
#'
#' @importFrom rlang %||% .data
#' @param df A data frame returned by [read_qualtrics()].
#' @param id_col Name of the column that uniquely identifies respondents.
#'   Default `"ResponseId"`.
#' @param timing_col Name of the first column containing the raw timing JSON
#'   strings.  Overflow columns named `<timing_col>_2`, `<timing_col>_3`, ...
#'   are picked up automatically.  Default `"timing"`.
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
  cols <- timing_columns(names(df), timing_col)

  # One list of normalized pages per respondent, gathered across every
  # timing column.
  pages <- purrr::pmap(unname(as.list(df[cols])), function(...) {
    pages <- unlist(
      purrr::map(list(...), parse_timing_field),
      recursive = FALSE
    )
    pages[order(purrr::map_int(pages, "page_index"))]
  })

  n_pages <- lengths(pages)
  pages <- unlist(pages, recursive = FALSE)
  n_events <- lengths(purrr::map(pages, "type"))

  page_col <- function(field, map_fn) {
    rep(map_fn(pages, field), n_events)
  }
  event_col <- function(field, empty) {
    unlist(purrr::map(pages, field)) %||% empty
  }
  as_time <- function(x) as.POSIXct(x, origin = "1970-01-01", tz = "UTC")

  dplyr::tibble(
    respondent = rep(rep(df[[id_col]], n_pages), n_events),
    page_index = page_col("page_index", purrr::map_int),
    load_time = as_time(page_col("load_time", purrr::map_dbl)),
    submit_time = as_time(page_col("submit_time", purrr::map_dbl)),
    type = event_col("type", character()),
    time = as_time(event_col("time", numeric())),
    input_type = event_col("input_type", character()),
    name = event_col("name", character())
  ) |>
    dplyr::mutate(
      t_since_load = as.numeric(difftime(time, load_time, units = "secs"))
    )
}

# The base timing column followed by its overflow columns in field order.
timing_columns <- function(nms, timing_col) {
  if (!timing_col %in% nms) {
    stop("Column `", timing_col, "` not found.", call. = FALSE)
  }
  extra <- grep(paste0("^", timing_col, "_[0-9]+$"), nms, value = TRUE)
  suffix <- as.integer(sub(".*_", "", extra))
  c(timing_col, extra[order(suffix)])
}

# Parse one field's JSON into a list of pages, each a list of page_index,
# load_time and submit_time (epoch seconds) plus parallel event vectors.
parse_timing_field <- function(x) {
  if (!is.character(x) || is.na(x) || !nzchar(x)) {
    return(list())
  }
  doc <- tryCatch(
    jsonlite::fromJSON(x, simplifyVector = FALSE),
    error = function(e) NULL
  )
  if (is.null(doc)) {
    return(list())
  }
  if (isTRUE(doc$v == 2)) {
    purrr::map(doc$p, normalize_page_v2)
  } else {
    purrr::map(doc$pages %||% list(), normalize_page_v1)
  }
}

event_types <- c(
  c = "change",
  k = "click",
  i = "input",
  h = "hidden",
  v = "visible",
  b = "window_blur",
  f = "window_focus"
)

# v2: {"i":0,"t":<epoch ms>,"s":<ms after load>,"e":[[ms, code, name, input_type]]}
normalize_page_v2 <- function(p) {
  load <- p$t / 1000
  e <- p$e %||% list()
  code <- vapply(e, function(x) as.character(x[[2]]), character(1))
  type <- unname(event_types[code])
  type[is.na(type)] <- code[is.na(type)]

  list(
    page_index = as.integer(p$i),
    load_time = load,
    submit_time = if (is.null(p$s)) NA_real_ else load + p$s / 1000,
    type = type,
    time = load + vapply(e, function(x) as.numeric(x[[1]]), numeric(1)) / 1000,
    input_type = vapply(e, event_field, character(1), 4L),
    name = vapply(e, event_field, character(1), 3L)
  )
}

event_field <- function(x, i) {
  if (length(x) >= i && !is.null(x[[i]])) as.character(x[[i]]) else
    NA_character_
}

# v1: {"page_index":0,"load_time":<ISO>,"submit_time":<ISO>,"events":[{...}]}
normalize_page_v1 <- function(p) {
  e <- p$events %||% list()
  chr <- function(field) {
    vapply(e, function(x) x[[field]] %||% NA_character_, character(1))
  }

  list(
    page_index = as.integer(p$page_index %||% NA_integer_),
    load_time = iso_seconds(p$load_time),
    submit_time = iso_seconds(p$submit_time),
    type = chr("type"),
    time = iso_seconds(chr("time")),
    input_type = chr("input_type"),
    name = chr("name")
  )
}

iso_seconds <- function(x) {
  if (is.null(x)) {
    return(NA_real_)
  }
  if (!length(x)) {
    return(numeric())
  }
  as.numeric(lubridate::ymd_hms(x, quiet = TRUE))
}
