# =====================================================================
# Creates example/odk_export_example.csv: a small, entirely synthetic
# ODK Central export (group-path headers, newest submission first), used
# by 01_wrangle.R. No real data is involved.
# Run from the repository root:  Rscript example/make_example_data.R
# =====================================================================
set.seed(42)
n     <- 30
times <- sort(as.POSIXct("2026-03-01 08:00:00", tz = "UTC") + sort(sample(0:(60 * 86400), n)), decreasing = TRUE)
codes <- sprintf("P%04d", sample(1:24, n, replace = TRUE))           # some participants have two visits
codes[c(5, 17)] <- ""                                                # two forms saved without a code
uuid  <- function() paste0("uuid:", paste(sample(c(0:9, letters[1:6]), 32, TRUE), collapse = ""))
keys  <- vapply(seq_len(n), function(i) uuid(), "")

example <- data.frame(
  "SubmissionDate"                  = format(times, "%Y-%m-%dT%H:%M:%OS3Z"),
  "grp_visit-visit_date"            = format(as.Date(times), "%Y-%m-%d"),
  "grp_visit-site"                  = sample(c("site_a", "site_b", "site_b_old", "site_c"), n, replace = TRUE),
  "grp_id-participant_code"         = codes,
  "grp_main-age_years"              = sample(18:80, n, replace = TRUE),
  "grp_main-q1_score"               = sample(1:5, n, replace = TRUE),
  "grp_main-gps-Latitude"           = round(runif(n, 0.001, 0.009), 6),   # placeholder coordinates
  "grp_main-gps-Longitude"          = round(runif(n, 0.001, 0.009), 6),
  "grp_main-gps-Altitude"           = round(runif(n, 1, 9), 1),
  "grp_main-gps-Accuracy"           = round(runif(n, 3, 12), 1),
  "notes"                           = "",
  "meta-instanceID"                 = keys,
  "meta-instanceName"               = paste0("survey_", format(as.Date(times))),
  "KEY"                             = keys,
  "SubmitterName"                   = "enumerator",
  "FormVersion"                     = "3",
  "ReviewState"                     = "",
  "Edits"                           = 0,
  check.names = FALSE
)
write.csv(example, "example/odk_export_example.csv", row.names = FALSE, na = "")
message("example/odk_export_example.csv written: ", n, " synthetic submissions")
