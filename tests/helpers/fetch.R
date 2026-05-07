# This API key needs to come from within the Qualtrics account of each person
# who runs this code.
api_key <- Sys.getenv("QUALTRICS_API_KEY")

# build the survey ID format required by qualtRics::fetch_survey. This is much
# faster than running the API call to Qualtrics using qualtRics::fetch_id and
# then extracting the id.
survey_id <- c("SV_eJyvrtnqCKPIDyK")
names(survey_id) <- "Response Timing"

qualtRics::qualtrics_api_credentials(
  api_key = api_key,
  base_url = "yul1.qualtrics.com",
  install = FALSE
)

df <- qualtRics::fetch_survey(
  surveyID = survey_id,
  include_display_order = FALSE,
  breakout_sets = TRUE,
  label = FALSE,
  convert = FALSE,
  add_column_map = TRUE,
  verbose = TRUE,
)

readr::write_csv(df, "survey_data.csv")
