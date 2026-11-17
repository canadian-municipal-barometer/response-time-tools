#' Read a Qualtrics CSV export
#'
#' Qualtrics exports have a header row plus 2 metadata rows (display order
#' and survey metadata).  This function keeps the header, skips the metadata,
#' and renames the JavaScript timing columns (`__js_timing`, `__js_timing_2`,
#' ...) to `"timing"`, `"timing_2"`, ... for easier reference.
#'
#' @param path Path to a Qualtrics CSV file.
#'
#' @return A [tibble][tibble::tibble-package] with one row per response, whose
#'   `"timing"` column (and any `"timing_2"`, `"timing_3"`, ... overflow
#'   columns) contains the raw JS timing JSON strings.
#' @export
#'
#' @examples
#' \dontrun{
#' read_qualtrics("survey_data.csv")
#' }
read_qualtrics <- function(path) {
  hdr <- readr::read_csv(path, n_max = 0, show_col_types = FALSE)
  df <- readr::read_csv(
    path,
    skip = 3,
    col_names = names(hdr),
    show_col_types = FALSE
  )
  dplyr::rename_with(
    df,
    ~ sub("^__js_", "", .x),
    dplyr::matches("^__js_timing(_[0-9]+)?$")
  )
}
