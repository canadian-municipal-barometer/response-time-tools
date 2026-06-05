#' Read a Qualtrics CSV export
#'
#' Qualtrics exports have a header row plus 2 metadata rows (display order
#' and survey metadata).  This function keeps the header, skips the metadata,
#' and renames the JavaScript timing column to `"timing"` for easier reference.
#'
#' @param path Path to a Qualtrics CSV file.
#'
#' @return A [tibble][tibble::tibble-package] with one row per response and an
#'   additional `"timing"` column containing the raw JS timing JSON strings.
#' @export
#'
#' @examples
#' \dontrun{
#' read_qualtrics("survey_data.csv")
#' }
read_qualtrics <- function(path) {
  hdr <- readr::read_csv(path, n_max = 0, show_col_types = FALSE)
  df <- readr::read_csv(path, skip = 3, col_names = names(hdr), show_col_types = FALSE)
  dplyr::rename(df, "timing" = "__js_timing")
}
