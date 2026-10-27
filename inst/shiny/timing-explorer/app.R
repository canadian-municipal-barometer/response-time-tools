# Standalone launcher for the timing explorer.
#
# Point TIMING_CSV at a Qualtrics export (defaults to the sample data shipped
# with the package), then run with shiny::runApp().
library(surveytiming)

path <- Sys.getenv("TIMING_CSV", unset = "")
if (!nzchar(path)) {
  path <- system.file("extdata", "survey_data.csv", package = "surveytiming")
}

raw <- read_qualtrics(path)
events <- parse_timing(raw)
timings <- question_timings(events)

timing_app(timings, events = events)
