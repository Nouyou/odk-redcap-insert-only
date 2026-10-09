# =====================================================================
# Step 1 of 2: prepare an ODK Central export for REDCap
#
# Reads the ODK export, keeps the variables that exist in REDCap, applies
# recodes, and writes the "final" CSV used by 02_push.R.
#
# record_id is NOT created here. It is created by the push, only for
# submissions that have never been sent, so the same submission can never
# end up with two different record IDs.
#
# The example uses the synthetic file example/odk_export_example.csv.
# Replace the file name and the select() list with your own form's variables.
# =====================================================================

library(dplyr)          # data handling
source("R/odk_helpers.R")

# -------------------------
# Read the ODK export
# -------------------------
# Use the raw download from ODK Central. Opening the CSV in Excel and saving it
# rewrites dates (2026-10-06 becomes 10/6/2026) and can change text.
raw <- read_odk_csv("example/odk_export_example.csv") |>
  add_submission_key()                                               # permanent key -> REDCap instance_id

# -------------------------
# Keep the REDCap variables (new name = ODK name)
# -------------------------
survey <- raw |>
  select(submission_date  = SubmissionDate,                          # ODK system columns renamed to REDCap fields
         visit_date, site, participant_code, age_years, q1_score,
         lat  = gps.Latitude,  long = gps.Longitude,                 # GPS sub-columns
         alt  = gps.Altitude,  acc  = gps.Accuracy,
         notes,
         instance_id   = submission_key,                             # permanent ODK key
         instance_name = instanceName,
         form_version  = FormVersion) |>
  mutate(site = if_else(site == "site_b_old", "site_b", site)) |>    # example recode: an old site code
  arrange(submission_date)                                           # oldest submission first

# -------------------------
# Write the file read by 02_push.R
# -------------------------
write.csv(survey, "final_survey_data.csv", row.names = FALSE, na = "")

# Quick check: number of rows, and rows without a submission key (should be 0;
# rows without a key cannot be tracked and are held back by the push)
c(rows = nrow(survey), no_key = sum(is.na(survey$instance_id)))
