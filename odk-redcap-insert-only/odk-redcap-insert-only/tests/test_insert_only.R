# =====================================================================
# Test suite: insert-only push against a simulated REDCap server
#
# Runs without a REDCap server and without real data. A fake REDCap is
# built in memory, the REDCapR read / write / logging functions are
# replaced by fakes, and synthetic ODK submissions are generated.
#
# Part A reproduces the problem with the usual "anti-join on record_id"
# push. Part B checks the four rules of the insert-only push.
#
# Run from the repository root:  Rscript tests/test_insert_only.R
# =====================================================================
suppressPackageStartupMessages({
  library(dplyr); library(readr); library(stringr); library(lubridate); library(tibble); library(REDCapR)
})
source("R/redcap_insert_only.R")
set.seed(2026)

work <- file.path(tempdir(), "insert_only_test")
unlink(work, recursive = TRUE); dir.create(work)

# ---------------------------------------------------------------------
# Synthetic ODK submissions (180 days, some codes submitted more than once,
# a few forms without a code)
# ---------------------------------------------------------------------
n      <- 220
start  <- as.POSIXct("2026-01-01 08:00:00", tz = "UTC")
times  <- sort(start + sort(sample(0:(180 * 86400), n)))
codes  <- sprintf("P%04d", sample(1:170, n, replace = TRUE))
codes[sample(n, 12)] <- NA                                           # forms without a code
odk <- tibble(
  submission_date  = format(times, "%Y-%m-%dT%H:%M:%OS3Z"),
  visit_date       = format(as.Date(times), "%Y-%m-%d"),
  site             = sample(c("site_a", "site_b", "site_c"), n, replace = TRUE),
  participant_code = codes,
  age_years        = as.character(sample(18:80, n, replace = TRUE)),
  q1_score         = as.character(sample(1:5, n, replace = TRUE)),
  notes            = NA_character_,
  instance_id      = paste0("uuid:", vapply(seq_len(n), function(i) paste(sample(c(0:9, letters[1:6]), 32, TRUE), collapse = ""), "")),
  instance_name    = paste0("survey_", format(as.Date(times))),
  form_version     = "3"
)
fields <- c("record_id", "submission_date", "visit_date", "site", "participant_code", "age_years",
            "q1_score", "notes", "instance_id", "instance_name", "form_version", "form_1_complete")

# ---------------------------------------------------------------------
# Fake REDCap
# ---------------------------------------------------------------------
FAKE <- new.env()
reset_fake <- function() {
  FAKE$data <- as_tibble(setNames(replicate(length(fields), character(), simplify = FALSE), fields))
  FAKE$log  <- tibble(timestamp = as.POSIXct(character()), username = character(), action = character(),
                      details = character(), record = character())
  FAKE$log_enabled <- TRUE; FAKE$read_fails <- FALSE; FAKE$reads <- 0L; FAKE$on_read <- NULL
}
add_log <- function(action, details, record) {
  FAKE$log <- bind_rows(FAKE$log, tibble(timestamp = Sys.time(), username = "api", action = action,
                                         details = details, record = record))
}
fake_read <- function(batch_size = 100L, interbatch_delay = 0.5, continue_on_error = FALSE, redcap_uri, token,
                      records = NULL, fields = NULL, ...) {
  FAKE$reads <- FAKE$reads + 1L
  if (!is.null(FAKE$on_read)) FAKE$on_read(FAKE$reads)
  if (isTRUE(FAKE$read_fails)) return(list(data = tibble(), success = FALSE, outcome_message = "The initial call failed with the code: 403."))
  if (nrow(FAKE$data) == 0) return(list(data = tibble(), success = TRUE, outcome_message = "zero rows"))
  d <- if (is.null(fields)) FAKE$data else FAKE$data[, unique(c("record_id", fields))]
  list(data = d, success = TRUE, outcome_message = "ok")
}
fake_write <- function(ds_to_write, batch_size = 100L, interbatch_delay = 0.5, continue_on_error = FALSE,
                       redcap_uri, token, overwrite_with_blanks = TRUE, ...) {
  ds <- ds_to_write |> mutate(across(everything(), as.character))
  bad <- setdiff(names(ds), fields)
  if (length(bad)) return(list(success = FALSE, outcome_message = paste("unknown fields:", paste(bad, collapse = ","))))
  for (i in seq_len(nrow(ds))) {
    vals <- unlist(ds[i, ], use.names = TRUE); id <- vals[["record_id"]]
    if (id %in% FAKE$data$record_id) {                               # REDCap import of an existing ID = UPDATE
      j <- which(FAKE$data$record_id == id)
      for (f in setdiff(names(vals), "record_id")) {
        if (!is.na(vals[[f]]) || overwrite_with_blanks) FAKE$data[[f]][j] <- unname(vals[[f]])
      }
      add_log("Update record (API)", "", id)
    } else {                                                         # new record
      row <- as_tibble(setNames(as.list(rep(NA_character_, length(fields))), fields))
      for (f in names(vals)) row[[f]] <- unname(vals[[f]])
      FAKE$data <- bind_rows(FAKE$data, row)
      keep <- !is.na(vals)
      add_log("Create record (API)", paste(sprintf("%s = '%s'", names(vals)[keep], vals[keep]), collapse = ", "), id)
    }
  }
  list(success = TRUE, outcome_message = sprintf("%d records were written to REDCap.", nrow(ds)),
       records_affected_count = nrow(ds), affected_ids = ds$record_id)
}
fake_variables <- function(redcap_uri, token, ...) {
  list(data = tibble(original_field_name = fields, choice_value = NA_character_, export_field_name = fields),
       success = TRUE, outcome_message = "ok")
}
fake_log_read <- function(redcap_uri, token, log_begin_date = Sys.Date() - 7L, log_end_date = Sys.Date(), ...) {
  if (!FAKE$log_enabled) return(list(data = tibble(), success = FALSE, outcome_message = "No logging right"))
  list(data = FAKE$log, success = TRUE, outcome_message = "ok")
}
assignInNamespace("redcap_read",      fake_read,      "REDCapR")
assignInNamespace("redcap_write",     fake_write,     "REDCapR")
assignInNamespace("redcap_variables", fake_variables, "REDCapR")
assignInNamespace("redcap_log_read",  fake_log_read,  "REDCapR")

# What the data team does in the REDCap web interface
ui_edit   <- function(id, field, value) { FAKE$data[[field]][FAKE$data$record_id == id] <- value
                                          add_log("Update record", sprintf("%s = '%s'", field, value), id) }
ui_rename <- function(old, new) { FAKE$data$record_id[FAKE$data$record_id == old] <- new
                                  add_log("Update record", sprintf("Record ID renamed from %s to %s", old, new), new) }
ui_delete <- function(id) { FAKE$data <- FAKE$data |> filter(record_id != id)
                            add_log("Delete record", sprintf("record_id = '%s'", id), id) }

# ---------------------------------------------------------------------
# Part A: the usual push (record_id = code + row number, anti-join on record_id)
# ---------------------------------------------------------------------
old_record_ids <- function(df) {                                     # ODK exports the newest submission first
  df |> arrange(desc(submission_date)) |>
    group_by(code = coalesce(participant_code, "")) |> mutate(n = row_number()) |> ungroup() |>
    mutate(record_id = paste(code, n, sep = "_")) |> select(-code, -n)
}
old_push <- function(export) {
  rc  <- FAKE$data
  new <- anti_join(old_record_ids(export), rc |> select(record_id), by = "record_id") |>
    mutate(submission_date = format_iso_to_redcap(submission_date))
  fake_write(new[, intersect(fields, names(new))], redcap_uri = "", token = "")   # default: overwrite_with_blanks = TRUE
  new
}

reset_fake()
cut1 <- "2026-03-01"; cut2 <- "2026-05-01"
invisible(old_push(odk |> filter(submission_date < cut1)))                    # first push
first <- FAKE$data
edited   <- sample(first$record_id, 15)                              # corrections made in REDCap
for (id in edited) ui_edit(id, "notes", "CORRECTED IN REDCAP")
pool     <- setdiff(first$record_id, edited)
renamed  <- sample(pool, 2); deleted <- sample(setdiff(pool, renamed), 2)
for (id in renamed) ui_rename(id, paste0(id, "x"))
for (id in deleted) ui_delete(id)
key_of   <- function(ids) first$instance_id[match(ids, first$record_id)]
before2  <- FAKE$data
sent2    <- old_push(odk |> filter(submission_date < cut2))          # second push, same method
new_subs <- setdiff(odk$instance_id[odk$submission_date < cut2], odk$instance_id[odk$submission_date < cut1])

cat("\n=== Part A: what the usual push did on its second run ===\n")
cat(sprintf("  old submissions sent again as extra records : %d\n", sum(sent2$instance_id %in% c(before2$instance_id, key_of(deleted)))))
cat(sprintf("    of which deleted records brought back     : %d of %d\n", sum(key_of(deleted) %in% sent2$instance_id), length(deleted)))
cat(sprintf("    of which renamed records sent again       : %d of %d\n", sum(key_of(renamed) %in% sent2$instance_id), length(renamed)))
cat(sprintf("  new submissions silently skipped           : %d of %d\n", sum(!new_subs %in% FAKE$data$instance_id), length(new_subs)))

# The team keeps working in REDCap before switching to the insert-only push
after2 <- FAKE$data
pool2  <- setdiff(after2$record_id, c(edited, paste0(renamed, "x"), sent2$record_id))
deleted2 <- sample(pool2, 2); renamed2 <- sample(setdiff(pool2, deleted2), 1)
del2_keys <- after2$instance_id[match(deleted2, after2$record_id)]
ren2_keys <- after2$instance_id[match(renamed2, after2$record_id)]
for (id in deleted2) ui_delete(id)
ui_rename(renamed2, paste0(renamed2, "x"))

# ---------------------------------------------------------------------
# Part B: the insert-only push
# ---------------------------------------------------------------------
csv <- file.path(work, "final_survey_data.csv")
write_csv(odk, csv, na = "")
cfg_for <- function(dry_run = FALSE, use_log = TRUE) {
  push_config(uri = "https://redcap.example.org/api/", dry_run = dry_run, use_redcap_log = use_log,
              registry_dir = file.path(work, "push_registry"), logs_dir = file.path(work, "push_logs"))
}
options(push.auto_yes = TRUE)
run <- function(...) {                                               # one push, console output kept short
  out <- NULL
  invisible(capture.output(out <- suppressMessages(tryCatch(
    push_project(csv, "token", "SURVEY", "participant_code", cfg_for(...)),
    error = function(e) e))))
  invisible(out)
}
results <- logical()
check <- function(label, ok) { results <<- c(results, ok); cat(sprintf("  [%s] %s\n", if (isTRUE(ok)) "PASS" else "FAIL", label)) }

snapshot <- FAKE$data; log_before <- FAKE$log
ever_keys <- unique(c(snapshot$instance_id, str_match(log_before$details, "\\binstance_id = '([^']+)'")[, 2]))
truly_new <- setdiff(odk$instance_id, ever_keys)

cat("\n=== Part B: insert-only push ===\n")
run(dry_run = TRUE)
check("dry run writes nothing", identical(FAKE$data, snapshot))

run(dry_run = FALSE)
after    <- FAKE$data
inserted <- after |> filter(!record_id %in% snapshot$record_id)
same_old <- after |> filter(record_id %in% snapshot$record_id) |> arrange(record_id)
check("rule 2: every existing record is unchanged", identical(as.data.frame(same_old), as.data.frame(arrange(snapshot, record_id))))
check("rule 3: corrections made in REDCap are kept", all(after$notes[after$record_id %in% edited] == "CORRECTED IN REDCAP"))
check("rule 4: deleted records are not sent again", !any(c(key_of(deleted), del2_keys) %in% inserted$instance_id))
check("renamed records are not sent again", !any(c(key_of(renamed), ren2_keys) %in% inserted$instance_id))
check("rule 1: exactly the never-sent submissions are inserted", setequal(inserted$instance_id, truly_new))
check("new record IDs never reuse an old, renamed or deleted ID", !any(inserted$record_id %in% c(snapshot$record_id, log_before$record)))
check("the push writes only creations, never updates", !any(FAKE$log$action[-seq_len(nrow(log_before))] == "Update record (API)"))
cat(sprintf("  (%d records before, %d inserted, %d copies from Part A listed by the audit)\n",
            nrow(snapshot), nrow(inserted), sum(duplicated(snapshot$instance_id))))

snapshot2 <- FAKE$data
run(dry_run = FALSE)
check("a second run inserts nothing", identical(FAKE$data, snapshot2))

gone <- inserted$record_id[1]; gone_key <- inserted$instance_id[1]
ui_delete(gone); FAKE$log_enabled <- FALSE
run(dry_run = FALSE)
check("a record deleted after a push stays deleted, even without the Logging right", !gone_key %in% FAKE$data$instance_id)

FAKE$log_enabled <- TRUE; FAKE$read_fails <- TRUE
out <- run(dry_run = FALSE)
check("if REDCap cannot be read, the push stops", inherits(out, "error") && grepl("could not be read", conditionMessage(out)))
FAKE$read_fails <- FALSE

extra <- odk[1, ] |> mutate(instance_id = "uuid:brand-new-submission", submission_date = "2026-07-15T10:00:00.000Z",
                            participant_code = "P9999")
write_csv(bind_rows(odk, extra), csv, na = "")
FAKE$reads <- 0L
FAKE$on_read <- function(k) if (k == 2) {                             # someone inserts the same ID between the checks
  FAKE$on_read <- NULL
  FAKE$data <- bind_rows(FAKE$data, tibble(record_id = "P9999_1", instance_id = "uuid:someone-else"))
}
out <- run(dry_run = FALSE)
check("a clash found just before writing aborts the write",
      inherits(out, "error") && !"uuid:brand-new-submission" %in% FAKE$data$instance_id)

run(dry_run = FALSE)
got <- FAKE$data |> filter(instance_id == "uuid:brand-new-submission")
check("the new submission then goes in once, with the next free ID (P9999_2)", nrow(got) == 1 && got$record_id == "P9999_2")

cat(sprintf("\n%d of %d checks passed\n", sum(results), length(results)))
if (!all(results)) quit(status = 1)
