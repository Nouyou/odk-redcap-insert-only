# =====================================================================
# Step 2 of 2: insert-only push to REDCap
#
#   1. Only submissions that have never been sent to REDCap are inserted.
#   2. Records that already exist in REDCap are never updated or overwritten.
#   3. Corrections made directly in REDCap are therefore kept.
#   4. Records deleted in REDCap are not sent again.
#
# How to run
#   1. Run 01_wrangle.R.
#   2. Run this script with dry_run = TRUE (nothing is written; review files
#      appear in push_logs/).
#   3. Check push_logs/<PROJECT>_to_push_<time>.csv.
#   4. Set dry_run = FALSE and run again to push. Then set it back to TRUE.
#
# Always run the whole script (RStudio: Source, Ctrl+Shift+S).
# =====================================================================

library(dplyr)
library(readr)
library(stringr)
library(lubridate)
library(tibble)
library(REDCapR)

if (utils::packageVersion("REDCapR") < "1.2.0") {
  stop("REDCapR 1.2.0 or newer is needed. Run install.packages('REDCapR') and restart R.")
}
source("R/redcap_insert_only.R")

# -------------------------
# Settings
# -------------------------
# The API address and the tokens are read from environment variables, so they
# never appear in this file. Put them in your personal .Renviron file
# (usethis::edit_r_environ(); see .Renviron.example), then restart R.
cfg <- push_config(
  uri              = Sys.getenv("REDCAP_URI"),   # e.g. https://redcap.example.org/api/
  dry_run          = TRUE,                       # TRUE = check only; FALSE = push
  use_redcap_log   = TRUE,                       # also read REDCap logging (needs the Logging right)
  log_start_date   = as.Date("2020-01-01"),      # must be earlier than the first push ever made
  missing_id_label = "NOID",                     # record_id base when the code is empty
  registry_dir     = "push_registry",            # keep and back up this folder
  logs_dir         = "push_logs"
)

# -------------------------
# Projects to push: one row per REDCap project
# -------------------------
# csv           file written by 01_wrangle.R
# token_var     name of the environment variable holding that project's token
# id_base_field column used as the first part of record_id (e.g. P0012_1, P0012_2)
projects <- tribble(
  ~project, ~csv,                    ~token_var,            ~id_base_field,
  "SURVEY", "final_survey_data.csv", "REDCAP_TOKEN_SURVEY", "participant_code"
  # add one line per extra project, e.g.
  # "FOLLOWUP", "final_followup_data.csv", "REDCAP_TOKEN_FOLLOWUP", "form_code"
)

# Stop before contacting REDCap if a token is missing
missing_tokens <- projects$token_var[!nzchar(Sys.getenv(projects$token_var))]
if (length(missing_tokens) > 0) stop("Token(s) not set: ", paste(missing_tokens, collapse = ", "),
                                     ". Add them to .Renviron and restart R.")

# -------------------------
# Run
# -------------------------
for (i in seq_len(nrow(projects))) {
  push_project(csv_path      = projects$csv[i],
               token         = Sys.getenv(projects$token_var[i]),
               project_name  = projects$project[i],
               id_base_field = projects$id_base_field[i],
               cfg           = cfg)
}
message("\nAll projects done", if (cfg$dry_run) " (dry run: nothing was written)." else ".")

# -------------------------
# Checks after the push (can be run line by line)
# -------------------------
# Last runs, one line per project
read_csv(file.path(cfg$logs_dir, "push_history.csv"), show_col_types = FALSE) |> tail(6)
# Running the script again straight after a push (dry_run = TRUE) should report
# 0 new submissions for every project.
