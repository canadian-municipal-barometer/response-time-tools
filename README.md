# Qualtrics Question Timing Tools

Track and analyze how long respondents spend on individual survey questions in Qualtrics.

## Overview

This toolkit enables per-question response timing analysis for Qualtrics surveys by:

1. **Embedding a timing logger** (`header.html`) into Qualtrics survey headers to capture client-side events (page loads, answer changes, focus/blur, visibility changes)
2. **Parsing timing data** (`parse.R`) to calculate time-on-question and generate visualizations

## Setup

### Prerequisites

- R with packages: `qualtRics`, `jsonlite`, `dplyr`, `tidyr`, `purrr`, `lubridate`, `ggplot2`, `readr`
- A Qualtrics API key set as the environment variable `QUALTRICS_API_KEY`

### Usage

1. **Add timing tracker to your survey** – Paste the contents of `header.html` into your Qualtrics survey's header (Look & Feel → Header) to begin collecting timing data. Note that Qualtrics doesn't parse text entered here very well, so it is recommended to use "edit" and then select "Source" (`<>`) before pasting in `header.html`.

2. **Parse and analyze timing data** – Run `parse.R` to generate a response-level table with time spent per question and optional visualizations:

   ```r
   source("parse.R")
   ```

## Output

- `response_q_times` – Wide-format table of question-level response times with one row per response and one column per question
- Event density, respondent timeline, and page duration plots (via `parse.R`)
