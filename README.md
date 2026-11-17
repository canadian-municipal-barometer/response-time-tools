# Qualtrics Question Timing Tools

Track and analyze how long respondents spend on individual survey questions in Qualtrics.

## Overview

This toolkit enables per-question response timing analysis for Qualtrics surveys by:

1. **Logging client-side events** (`inst/js/survey-timing.js`) — page loads, answer changes, focus/blur, and visibility changes — into a Qualtrics embedded data field
2. **Parsing that log in R** (the `surveytiming` package) to calculate time-on-question

## Setup

### 1. Add the timing logger to your survey

Create embedded data fields named `__js_timing`, `__js_timing_2` and
`__js_timing_3` in the survey flow **before** the first question block.

Qualtrics refuses a page submit when any one embedded data value is over
20,000 bytes, and the respondent cannot get past that page. So the logger
never lets a field grow beyond 19,500 bytes: once `timing` is full it moves on
to `timing_2`, then `timing_3`. Each page takes roughly 100 bytes, so three
fields hold several hundred pages. If all three fill up, later pages are
trimmed, then dropped, and the survey keeps working.

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
  data-max-fields="3"
  data-debounce="500"
  data-debug="false"
></script>
```

| Attribute         | Default  | Meaning                                                                                                                                                  |
| ----------------- | -------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `data-field`      | `timing` | Embedded data field the event log is written to; Qualtrics prefixes it, so it lands in `__js_timing`. Overflow goes to `<field>_2`, `<field>_3`, ... |
| `data-max-fields` | `3`      | How many fields the log may spread across. Declare every one of them in the survey flow                                                                 |
| `data-debounce`   | `500`    | Idle milliseconds before a typing burst is logged as one `input` event                                                                                  |
| `data-debug`      | `false`  | `true` mirrors every logged event to the browser console (testing only)                                                                                 |

To check the logger while previewing a survey, open the browser console and
run `SurveyTiming.state()` for the log written so far, `SurveyTiming.page()`
for the page in progress, or `SurveyTiming.bytes()` for how full each field
is. To watch the overflow happen without clicking through hundreds of pages,
set `window.SURVEY_TIMING_CONFIG = { maxBytes: 1500 }` in a script placed
before the logger's tag.

Each field holds a compact JSON log (format v2):

```json
{"v":2,"p":[{"i":0,"t":1761590000000,"s":15234,"e":[[812,"c","QID5","radio"]]}]}
```

`i` is the page index, `t` the page load time in epoch milliseconds, `s` the
submit time in milliseconds after load, and `e` the events as
`[ms after load, type, question id, input type]`. Type codes are `c` change,
`k` click, `i` input, `h` hidden, `v` visible, `b` window blur and `f` window
focus. A page trimmed to fit carries `d`, the number of events dropped from its
end. `parse_timing()` decodes all of this, and still reads logs in the
original v1 format.

### 2. Parse and analyze the timing data

Prerequisites: R with `qualtRics`, `jsonlite`, `dplyr`, `tidyr`, `purrr`,
`lubridate`, `readr`, `rlang`, and a Qualtrics API key in the environment
variable `QUALTRICS_API_KEY`.

```r
raw     <- read_qualtrics("survey_data.csv")  # export with the timing column
events  <- parse_timing(raw)                  # one row per logged event
qtimes  <- question_timings(events)           # one row per question answered
```

- `parse_timing()` reads `timing` and any `timing_2`, `timing_3`, ... overflow
  columns and flattens the JSON into a long event table (`respondent`,
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
