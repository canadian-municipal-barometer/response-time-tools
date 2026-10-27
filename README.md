# Qualtrics Question Timing Tools

Track and analyze how long respondents spend on individual survey questions in Qualtrics.

## Overview

This toolkit enables per-question response timing analysis for Qualtrics surveys by:

1. **Logging client-side events** (`inst/js/survey-timing.js`) — page loads, answer changes, focus/blur, and visibility changes — into a Qualtrics embedded data field
2. **Parsing that log in R** (the `surveytiming` package) to calculate time-on-question

## Setup

### 1. Add the timing logger to your survey

Create an embedded data field named `__js_timing` in the survey flow **before** the
first question block. Without this, Qualtrics silently writes to a field that does not export
exist, so this step is not optional.

Then go to **Look & Feel → Header**, click **edit**, switch to **Source**
(`<>`) — Qualtrics mangles anything pasted outside source view — and paste:

```html
<script src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"></script>
```

That URL is served by GitHub Pages from this repo's `prod` branch, so the
survey always loads the published version of the script and the header never
has to be re-pasted when the logger changes.

Optional settings go on the script tag itself:

```html
<script
  src="https://canadian-municipal-barometer.github.io/response-time-tools/survey-timing.js"
  data-field="timing"
  data-debounce="500"
  data-debug="false"
></script>
```

| Attribute       | Default  | Meaning                                                                 |
| --------------- | -------- | ----------------------------------------------------------------------- |
| `data-field`    | `timing` | Embedded data field the event log is written to                         |
| `data-debounce` | `500`    | Idle milliseconds before a typing burst is logged as one `input` event  |
| `data-debug`    | `false`  | `true` mirrors every logged event to the browser console (testing only) |

To check the logger while previewing a survey, open the browser console and
run `SurveyTiming.state()` for the log written so far, or `SurveyTiming.page()`
for the page in progress.

### 2. Parse and analyze the timing data

Prerequisites: R with `qualtRics`, `jsonlite`, `dplyr`, `tidyr`, `purrr`,
`lubridate`, `readr`, `rlang`, and a Qualtrics API key in the environment
variable `QUALTRICS_API_KEY`.

```r
raw     <- read_qualtrics("survey_data.csv")  # export with the timing column
events  <- parse_timing(raw)                  # one row per logged event
qtimes  <- question_timings(events)           # one row per question answered
```

- `parse_timing()` flattens the JSON into a long event table (`respondent`,
  `page_index`, `load_time`, `submit_time`, `type`, `time`, `input_type`,
  `name`, `t_since_load`).
- `question_timings()` estimates `time_on_q` per respondent-page-question,
  measuring from the later of the previous answer or the page load, adjusted
  forward to the last focus/visibility event before the answer.

`tests/helpers/fetch.R` pulls a fresh export straight from the Qualtrics API
if you would rather not download a CSV by hand.

### 3. Explore the timings interactively

`timing_app()` opens a Shiny app on the output of `question_timings()`
(requires `shiny`, `bslib`, and `plotly`):

```r
timing_app(qtimes, events = events)
```

- **Timeline** — a wide, horizontally scrollable bar chart of response time in
  survey order, with a toggle between per-question and per-page bars. The
  sidebar filters the scope from a single respondent up to the whole dataset
  (respondents, pages, questions, time range); across multiple respondents the
  bars show the median or mean with an IQR or SD interval and, optionally, the
  individual responses overlaid. Clicking a bar opens that question in the
  distribution view.
- **Distribution** — a histogram and box plot for one question, plus central
  tendency and variance statistics (mean, median, SD, variance, IQR, MAD,
  coefficient of variation, skewness, and quantiles).

Pass `events` to let the per-page view measure page duration from page load to
page submit instead of summing its question times, and `labels` (a data frame
with `qid` and `label` columns, e.g. from `qualtRics::extract_colmap()`) to
show readable question names.

`inst/shiny/timing-explorer/app.R` runs the same app standalone; set the
`TIMING_CSV` environment variable to point it at an export.

## Publishing changes to the logger

`main` is the source of truth (`inst/js/survey-timing.js`). GitHub Pages serves
the `prod` branch, and nothing reaches live surveys until you publish:

```sh
tools/publish.sh
```

This copies the script to `prod` and pushes. Pages caches for roughly ten
minutes; append `?v=2` (any changing value) to the URL in the survey header to
force respondents onto a new version immediately.
