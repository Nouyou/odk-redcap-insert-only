# =====================================================================
# Insert-only push of ODK submissions to REDCap
# Functions only: nothing runs when this file is sourced.
#
# Rules
#   1. Only submissions that have never been sent to REDCap are inserted.
#   2. Records that already exist in REDCap are never updated or overwritten.
#   3. Corrections made directly in REDCap are therefore kept.
#   4. Records deleted in REDCap are not sent again.
#
# A submission is recognised by its ODK submission key (REDCap field
# instance_id), never by record_id: record_id can be renamed in REDCap, and a
# record_id built from row order changes from one export to the next.
#
# Needs: dplyr, readr, stringr, lubridate, tibble, REDCapR (>= 1.2.0)
# =====================================================================

# -------------------------
# Settings shared by every function
# -------------------------
# uri              REDCap API address, e.g. https://redcap.example.org/api/
# dry_run          TRUE = prepare and check only, nothing is written to REDCap
# use_redcap_log   TRUE = also read REDCap logging to find records deleted in the past
# log_start_date   logging is read from this date; must be before the first ever push
# missing_id_label used in record_id when the code column is empty (NOID_1, NOID_2, ...)
# registry_dir     folder for the push registry and the do-not-push lists
# logs_dir         folder for review files, audit files and the push history
push_config <- function(uri,
                        dry_run          = TRUE,
                        use_redcap_log   = TRUE,
                        log_start_date   = as.Date("2020-01-01"),
                        missing_id_label = "NOID",
                        registry_dir     = "push_registry",
                        logs_dir         = "push_logs") {
  if (!nzchar(uri)) stop("REDCap API address is empty. Set REDCAP_URI in your .Renviron file.")
  dir.create(registry_dir, showWarnings = FALSE, recursive = TRUE)  # created on the first run only
  dir.create(logs_dir,     showWarnings = FALSE, recursive = TRUE)
  list(uri = uri, dry_run = dry_run, use_redcap_log = use_redcap_log,
       log_start_date = as.Date(log_start_date), missing_id_label = missing_id_label,
       registry_dir = registry_dir, logs_dir = logs_dir)
}

# -------------------------
# ODK date-time (2026-10-06T09:15:02.337Z) -> REDCap text (2026-10-06 09:15:02)
# Other common formats are also converted; a value that cannot be read is left as it is.
# -------------------------
format_iso_to_redcap <- function(x) {
  x_chr   <- dplyr::na_if(stringr::str_trim(as.character(x)), "")    # text, empty -> NA
  iso_idx <- grepl("T.*Z$", x_chr)                                   # ODK ISO format
  if (any(iso_idx, na.rm = TRUE)) {
    x_chr[iso_idx] <- format(as.POSIXct(x_chr[iso_idx], format = "%Y-%m-%dT%H:%M:%OSZ", tz = "UTC"),
                             "%Y-%m-%d %H:%M:%S")
  }
  rem_idx <- !is.na(x_chr)                                           # every non-empty value
  if (any(rem_idx)) {
    parsed <- suppressWarnings(lubridate::parse_date_time(x_chr[rem_idx],
                               orders = c("Ymd HMS", "Ymd HM", "Ymd", "dmY HMS", "dmY")))
    x_chr[rem_idx] <- ifelse(!is.na(parsed), format(parsed, "%Y-%m-%d %H:%M:%S"), x_chr[rem_idx])
  }
  x_chr
}

# -------------------------
# Read a CSV with every column as text
# -------------------------
safe_read <- function(path) {
  if (!file.exists(path)) stop("File not found: ", path)             # stop early if the file is missing
  readr::read_csv(path, col_types = readr::cols(.default = "c"), show_col_types = FALSE)
}

# -------------------------
# Ask for YES in the console
# -------------------------
# When the script runs without a console (Rscript, scheduled task), nobody can
# type YES, so the answer is "no" unless options(push.auto_yes = TRUE) was set.
ask_yes <- function(question) {
  if (!interactive()) return(isTRUE(getOption("push.auto_yes", FALSE)))
  answer <- readline(paste0(question, " Type YES to continue, anything else to cancel: "))
  toupper(stringr::str_trim(answer)) == "YES"
}

# -------------------------
# Read record_id, instance_id and submission_date of every REDCap record
# -------------------------
# Stops if REDCap cannot be read: pushing without knowing what is already
# in REDCap is never allowed.
rc_read_keys <- function(token, project_name, cfg) {
  res <- REDCapR::redcap_read(
    redcap_uri = cfg$uri,
    token      = token,
    fields     = c("record_id", "instance_id", "submission_date"),
    col_types  = readr::cols(.default = readr::col_character()),     # keep IDs exactly as stored
    verbose    = FALSE
  )
  if (!isTRUE(res$success)) {
    stop(project_name, ": REDCap could not be read (", res$outcome_message,
         "). Check the token and its API export right. Nothing was pushed.")
  }
  if (nrow(res$data) == 0) {                                         # empty project
    return(tibble::tibble(record_id = character(), instance_id = character(), submission_date = character()))
  }
  res$data |>
    dplyr::transmute(record_id       = stringr::str_trim(record_id),
                     instance_id     = dplyr::na_if(stringr::str_trim(instance_id), ""),
                     submission_date = dplyr::na_if(stringr::str_trim(submission_date), ""))
}

# -------------------------
# Names of the REDCap fields of a project (only these columns are sent)
# -------------------------
# Form status fields (<form>_complete) are left out so REDCap sets them itself.
rc_field_names <- function(token, project_name, cfg) {
  res <- REDCapR::redcap_variables(redcap_uri = cfg$uri, token = token, verbose = FALSE)
  if (!isTRUE(res$success)) stop(project_name, ": REDCap field list could not be read (", res$outcome_message, ").")
  fields <- res$data$export_field_name
  fields[!grepl("_complete$", fields)]
}

# -------------------------
# instance_ids found in the REDCap logging (records created, edited or deleted)
# -------------------------
# Needs the "Logging" user right for the API user. If logging cannot be read,
# a message is shown and the push continues with the registry and do-not-push list only.
rc_logged_keys <- function(token, project_name, cfg) {
  empty <- tibble::tibble(instance_id = character(), record_id = character())
  res <- tryCatch(
    REDCapR::redcap_log_read(redcap_uri = cfg$uri, token = token,
                             log_begin_date = cfg$log_start_date, log_end_date = Sys.Date(),
                             verbose = FALSE),
    error = function(e) NULL
  )
  if (is.null(res) || !isTRUE(res$success) || !"details" %in% names(res$data)) {
    message(project_name, ": REDCap logging could not be read (the API user may not have the Logging right).\n",
            "   Records deleted BEFORE this script was first used can then only be blocked\n",
            "   through ", do_not_push_file(project_name, cfg), ".")
    return(empty)
  }
  lg   <- res$data
  keys <- stringr::str_match(lg$details, "\\binstance_id = '([^']+)'")[, 2]   # logged text: instance_id = 'uuid:...'
  ids  <- if ("record" %in% names(lg)) lg$record else stringr::str_match(lg$details, "\\brecord_id = '([^']+)'")[, 2]
  tibble::tibble(instance_id = stringr::str_trim(keys), record_id = stringr::str_trim(ids)) |>
    dplyr::filter(!is.na(instance_id)) |>
    dplyr::distinct(instance_id, .keep_all = TRUE)
}

# -------------------------
# Push registry: every instance_id sent to, or seen in, REDCap
# -------------------------
registry_file    <- function(project_name, cfg) file.path(cfg$registry_dir, paste0(project_name, "_registry.csv"))
do_not_push_file <- function(project_name, cfg) file.path(cfg$registry_dir, paste0(project_name, "_do_not_push.csv"))

read_registry <- function(project_name, cfg) {
  f <- registry_file(project_name, cfg)
  if (!file.exists(f)) {                                             # first run: empty registry
    return(tibble::tibble(instance_id = character(), record_id = character(),
                          recorded_at = character(), source = character()))
  }
  safe_read(f)
}

# Adds entries whose instance_id is not yet in the registry; existing entries are never changed
add_to_registry <- function(registry, entries, source_label) {
  to_add <- entries |>
    dplyr::filter(!is.na(instance_id), !instance_id %in% registry$instance_id) |>
    dplyr::distinct(instance_id, .keep_all = TRUE) |>
    dplyr::transmute(instance_id, record_id,
                     recorded_at = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                     source      = source_label)
  dplyr::bind_rows(registry, to_add)
}

# do-not-push list (created empty on the first run, filled in by hand when needed)
read_do_not_push <- function(project_name, cfg) {
  f <- do_not_push_file(project_name, cfg)
  if (!file.exists(f)) {
    readr::write_csv(tibble::tibble(instance_id = character(), reason = character()), f)
    return(character())
  }
  x <- safe_read(f)
  if (!"instance_id" %in% names(x)) stop(f, " must have a column called instance_id")
  unique(stats::na.omit(stringr::str_trim(x$instance_id)))
}

# -------------------------
# New record_ids: <code>_<highest number already used for that code + 1>
# -------------------------
# used_ids = every record_id in REDCap now, in the registry and in the logging,
# so a number is never given twice, even if the record was renamed or deleted.
assign_record_ids <- function(base, used_ids, missing_id_label = "NOID") {
  base <- stringr::str_trim(base)
  base[is.na(base) | base == ""] <- missing_id_label                 # empty code -> NOID
  used <- unique(stats::na.omit(used_ids))
  out  <- character(length(base))
  for (i in seq_along(base)) {
    prefix  <- paste0(base[i], "_")
    same    <- used[startsWith(used, prefix)]                        # IDs already used with this code
    suffix  <- substring(same, nchar(prefix) + 1)                    # the part after "<code>_"
    numbers <- as.integer(suffix[grepl("^[0-9]+$", suffix)])         # numeric suffixes only
    next_n  <- if (length(numbers) == 0) 1L else max(numbers) + 1L
    out[i]  <- paste0(prefix, next_n)
    used    <- c(used, out[i])                                       # reserve it for the next rows
  }
  out
}

# -------------------------
# One line per project per run in <logs_dir>/push_history.csv
# -------------------------
write_history <- function(project_name, cfg, csv_rows, redcap_rows, new_rows, written) {
  line <- tibble::tibble(run_at        = format(Sys.time(), "%Y-%m-%d %H:%M:%S"),
                         project       = project_name,
                         dry_run       = cfg$dry_run,
                         odk_rows      = csv_rows,
                         redcap_before = redcap_rows,
                         new_found     = new_rows,
                         inserted      = written,
                         run_by        = Sys.info()[["user"]])
  f <- file.path(cfg$logs_dir, "push_history.csv")
  readr::write_csv(line, f, append = file.exists(f), na = "")       # header written only the first time
}

# =====================================================================
# Core function: insert-only push of one project
# =====================================================================
# csv_path      CSV prepared by the wrangling step (must contain instance_id,
#               submission_date and the code column named in id_base_field)
# token         REDCap API token of the project
# project_name  short name used in messages and file names
# id_base_field column used as the first part of record_id
# cfg           settings from push_config()
push_project <- function(csv_path, token, project_name, id_base_field, cfg) {
  message("\n==================== ", project_name, " ====================")
  stamp    <- format(Sys.time(), "%Y%m%d_%H%M%S")                    # time stamp for output file names
  out_file <- function(what) file.path(cfg$logs_dir, paste0(project_name, "_", what, "_", stamp, ".csv"))

  # ---- 1. ODK data prepared by the wrangling step --------------------
  df <- safe_read(csv_path)
  needed <- c("instance_id", "submission_date", id_base_field)
  if (length(setdiff(needed, names(df))) > 0) {
    stop(project_name, ": column(s) missing in ", csv_path, ": ", paste(setdiff(needed, names(df)), collapse = ", "))
  }
  df <- df |>
    dplyr::select(-dplyr::any_of("record_id")) |>                   # record_id is created below, never taken from the CSV
    dplyr::mutate(instance_id     = dplyr::na_if(stringr::str_trim(instance_id), ""),
                  submission_date = format_iso_to_redcap(submission_date))
  message(project_name, ": ", nrow(df), " submissions in ", csv_path)

  no_key <- df |> dplyr::filter(is.na(instance_id))                 # cannot be tracked -> held back
  if (nrow(no_key) > 0) {
    readr::write_csv(no_key, out_file("held_back_no_instance_id"), na = "")
    message(project_name, ": ", nrow(no_key), " submissions without instance_id held back (see ", cfg$logs_dir, ").")
  }
  n_with_key <- nrow(df) - nrow(no_key)
  df <- df |>
    dplyr::filter(!is.na(instance_id)) |>
    dplyr::distinct(instance_id, .keep_all = TRUE)                  # one row per submission
  if (nrow(df) < n_with_key) {
    message(project_name, ": ", n_with_key - nrow(df), " repeated instance_id rows in the CSV ignored (first one kept).")
  }

  # ---- 2. What REDCap holds right now --------------------------------
  rc <- rc_read_keys(token, project_name, cfg)
  message(project_name, ": ", nrow(rc), " records in REDCap")

  # ---- 3. Audit of REDCap --------------------------------------------
  # Same instance_id in more than one record = the same ODK submission exists
  # twice (typically an uncorrected copy re-created by an earlier push).
  # Nothing is changed in REDCap; the list is for the data manager.
  rc_dups <- rc |>
    dplyr::filter(!is.na(instance_id)) |>
    dplyr::group_by(instance_id) |>
    dplyr::filter(dplyr::n() > 1) |>
    dplyr::ungroup() |>
    dplyr::arrange(instance_id, record_id)
  if (nrow(rc_dups) > 0) {
    readr::write_csv(rc_dups, out_file("REDCap_duplicates"), na = "")
    message(project_name, ": ", dplyr::n_distinct(rc_dups$instance_id), " ODK submissions appear in more than one REDCap record (",
            nrow(rc_dups), " records). Review the *_REDCap_duplicates_* file and delete the unwanted copy in REDCap;\n",
            "   it will not be sent again.")
  }
  rc_no_key <- rc |> dplyr::filter(is.na(instance_id))              # REDCap records without instance_id
  if (nrow(rc_no_key) > 0) {
    message(project_name, ": ", nrow(rc_no_key), " REDCap records have no instance_id; they are matched on submission_date instead.")
  }

  # ---- 4. Every instance_id already known ----------------------------
  registry    <- read_registry(project_name, cfg)
  logged      <- if (cfg$use_redcap_log) rc_logged_keys(token, project_name, cfg) else
                   tibble::tibble(instance_id = character(), record_id = character())
  do_not_push <- read_do_not_push(project_name, cfg)

  # Keep the registry up to date: records now in REDCap, then records only found in the logging
  registry <- registry |>
    add_to_registry(rc |> dplyr::select(instance_id, record_id), "found in REDCap") |>
    add_to_registry(logged, "found in REDCap logging only (deleted)")
  readr::write_csv(registry, registry_file(project_name, cfg), na = "")

  # ---- 5. Keep only submissions never sent before --------------------
  status_tbl <- df |>
    dplyr::transmute(instance_id,
                     status = dplyr::case_when(
                       instance_id %in% rc$instance_id       ~ "already in REDCap (left untouched)",
                       instance_id %in% do_not_push          ~ "in do-not-push list",
                       instance_id %in% registry$instance_id ~ "sent before, no longer in REDCap (deleted)",
                       TRUE                                  ~ "new"))
  print(dplyr::count(status_tbl, status, name = "submissions"))     # summary table in the console

  new_rows <- df |> dplyr::filter(instance_id %in% status_tbl$instance_id[status_tbl$status == "new"])

  # REDCap records without instance_id: a new row with the same submission_date is held back
  if (nrow(rc_no_key) > 0 && nrow(new_rows) > 0) {
    same_time <- new_rows |> dplyr::filter(submission_date %in% rc_no_key$submission_date)
    if (nrow(same_time) > 0) {
      readr::write_csv(same_time, out_file("held_back_same_submission_date"), na = "")
      message(project_name, ": ", nrow(same_time), " new rows held back: same submission_date as a REDCap record without instance_id.")
      new_rows <- new_rows |> dplyr::filter(!instance_id %in% same_time$instance_id)
    }
  }

  if (nrow(new_rows) == 0) {
    message(project_name, ": nothing new to push.")
    write_history(project_name, cfg, csv_rows = nrow(df), redcap_rows = nrow(rc), new_rows = 0, written = 0)
    return(invisible(tibble::tibble()))
  }

  # ---- 6. record_id for the new submissions (oldest first) -----------
  used_ids <- c(rc$record_id, registry$record_id, logged$record_id)
  new_rows <- new_rows |>
    dplyr::arrange(submission_date) |>                              # older submissions get the lower numbers
    dplyr::mutate(record_id = assign_record_ids(.data[[id_base_field]], used_ids, cfg$missing_id_label))
  codes <- new_rows[[id_base_field]]                                 # kept for the review file

  # ---- 7. Keep only the columns that exist in REDCap -----------------
  rc_fields <- rc_field_names(token, project_name, cfg)
  if (rc_fields[1] != "record_id") stop(project_name, ": the first REDCap field is '", rc_fields[1], "', expected 'record_id'.")
  not_in_redcap <- setdiff(names(new_rows), rc_fields)
  if (length(not_in_redcap) > 0) {
    message(project_name, ": columns not in the REDCap project, not sent: ", paste(not_in_redcap, collapse = ", "))
  }
  new_rows <- new_rows |> dplyr::select(dplyr::any_of(rc_fields))  # REDCap field order, record_id first

  # ---- 8. Review file ------------------------------------------------
  # older_than_latest_in_redcap = TRUE: submitted before the most recent record
  # already in REDCap. Usually a submission missed earlier; if it is a record
  # that was deleted on purpose, add its instance_id to the do-not-push list.
  latest_in_rc <- if (any(!is.na(rc$submission_date))) max(rc$submission_date, na.rm = TRUE) else NA_character_
  review <- new_rows |>
    dplyr::transmute(record_id, instance_id, code = codes, submission_date,
                     older_than_latest_in_redcap = !is.na(latest_in_rc) & !is.na(submission_date) &
                                                   submission_date < latest_in_rc)   # text comparison works for "YYYY-MM-DD HH:MM:SS"
  readr::write_csv(review, out_file("to_push"), na = "")
  message(project_name, ": ", nrow(new_rows), " new submissions to push (",
          sum(review$older_than_latest_in_redcap), " older than the latest record in REDCap). List: ", out_file("to_push"))

  if (cfg$dry_run) {
    message(project_name, ": dry run - nothing written to REDCap.")
    write_history(project_name, cfg, csv_rows = nrow(df), redcap_rows = nrow(rc), new_rows = nrow(new_rows), written = 0)
    return(invisible(review))
  }

  # ---- 9. Confirmation ------------------------------------------------
  if (!ask_yes(paste0(project_name, ": insert ", nrow(new_rows), " NEW records into REDCap?"))) {
    message(project_name, ": push cancelled. Nothing was written.")  # the next project still runs
    write_history(project_name, cfg, csv_rows = nrow(df), redcap_rows = nrow(rc), new_rows = nrow(new_rows), written = 0)
    return(invisible(review))
  }

  # ---- 10. Final safety check: read REDCap again just before writing --
  rc_now <- rc_read_keys(token, project_name, cfg)
  clash  <- new_rows |>
    dplyr::filter(record_id %in% rc_now$record_id | instance_id %in% rc_now$instance_id)
  if (nrow(clash) > 0) {
    readr::write_csv(clash |> dplyr::select(record_id, instance_id), out_file("ABORTED_clash"), na = "")
    stop(project_name, ": ", nrow(clash), " rows already exist in REDCap (same record_id or instance_id). ",
         "Nothing was written. See the *_ABORTED_clash_* file.")
  }

  # ---- 11. Write the new records -------------------------------------
  res <- REDCapR::redcap_write(
    ds_to_write           = new_rows,
    redcap_uri            = cfg$uri,
    token                 = token,
    overwrite_with_blanks = FALSE                                   # empty cells never blank out a value
  )
  message(project_name, ": ", res$outcome_message)

  # ---- 12. Record what is now in REDCap --------------------------------
  rc_after <- rc_read_keys(token, project_name, cfg)
  written  <- new_rows |> dplyr::filter(instance_id %in% rc_after$instance_id)   # rows that really arrived
  registry <- add_to_registry(registry, written |> dplyr::select(instance_id, record_id), paste0("pushed ", stamp))
  readr::write_csv(registry, registry_file(project_name, cfg), na = "")
  readr::write_csv(written, out_file("pushed"), na = "")
  if (nrow(written) < nrow(new_rows)) {
    warning(project_name, ": ", nrow(new_rows) - nrow(written), " of ", nrow(new_rows),
            " rows did not reach REDCap (", res$outcome_message, "). They will be offered again next time.")
  }
  message(project_name, ": ", nrow(written), " new records inserted.")
  write_history(project_name, cfg, csv_rows = nrow(df), redcap_rows = nrow(rc), new_rows = nrow(new_rows), written = nrow(written))
  invisible(written)
}
