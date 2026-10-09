# How the insert-only push works

This page describes what happens inside `push_project()` (in `R/redcap_insert_only.R`) and which files it creates. The step numbers match the comments in the code.

## Settings

All settings are passed through `push_config()` in `02_push.R`.

| Setting | Default | Meaning |
|---|---|---|
| `uri` | read from `REDCAP_URI` | REDCap API address |
| `dry_run` | `TRUE` | `TRUE` prepares and checks everything but writes nothing. Set it to `FALSE` only for the real push, then back to `TRUE`. |
| `use_redcap_log` | `TRUE` | Also reads the REDCap logging, so records deleted in the past are recognised and not sent again. |
| `log_start_date` | `2020-01-01` | Date from which the logging is read. Must be earlier than the first push ever made. |
| `missing_id_label` | `"NOID"` | Base of `record_id` when the code is empty (`NOID_1`, `NOID_2`, ...). |
| `registry_dir` | `push_registry` | Folder for the registry and the do-not-push lists. |
| `logs_dir` | `push_logs` | Folder for review files, audit files and the push history. |

## The twelve steps of `push_project()`

1. **ODK data.** Reads the final CSV, removes any `record_id` column, converts `submission_date` to `YYYY-MM-DD HH:MM:SS` and holds back rows without an `instance_id`. Repeated keys are kept once.
2. **What REDCap holds now.** Reads `record_id`, `instance_id` and `submission_date` of every REDCap record. If REDCap cannot be read, the push stops.
3. **Audit.** Lists any submission that appears in more than one REDCap record, and any REDCap record without an `instance_id`. Nothing in REDCap is changed.
4. **Every key already known.** Reads the registry, the REDCap logging and the do-not-push list, then adds to the registry every key now in REDCap and every key found only in the logging (deleted records).
5. **Keep only new submissions.** Classifies each ODK submission and prints a summary table. Only rows classified as `new` go further. If REDCap holds records without an `instance_id`, any new row with the same submission date is held back for a manual check.
6. **Record IDs.** Sorts the new rows oldest first and gives each one a record ID that has never been used (see below).
7. **REDCap columns only.** Keeps the columns that exist in the REDCap project, in REDCap's order, and names any column that is left out.
8. **Review file.** Writes `<PROJECT>_to_push_<time>.csv` and flags rows submitted before the most recent record already in REDCap. In a dry run the function stops here.
9. **Confirmation.** Asks for YES in the console. Any other answer cancels the push for that project only. When the script runs without a console, the answer is no unless `options(push.auto_yes = TRUE)` was set.
10. **Final safety check.** Reads REDCap again. If any record ID or key of the batch is already there, nothing is written and the clash is saved to a file.
11. **Write.** Sends the new records with `overwrite_with_blanks = FALSE`, in batches of 100.
12. **Record the result.** Reads REDCap once more, adds only the rows that really arrived to the registry, saves them to `<PROJECT>_pushed_<time>.csv` and writes a line in `push_history.csv`. Rows that did not arrive are reported and will be offered again next time.

## How record IDs are built

A new record ID is the code followed by an underscore and the next free number. The numbers already used are collected from REDCap, the registry and the logging, so the IDs of renamed or deleted records are never reused.

| Situation | IDs already used for that code | New record ID |
|---|---|---|
| First submission for participant P0025 | none | `P0025_1` |
| Second submission for the same participant | `P0025_1` | `P0025_2` |
| Same participant after `P0025_2` was deleted in REDCap | `P0025_1`, and `P0025_2` in the logging | `P0025_3` |
| A form saved without a code | `NOID_1` to `NOID_6` | `NOID_7` |

## Files created by the push

| File | Folder | Contents | What to do |
|---|---|---|---|
| `<PROJECT>_registry.csv` | `push_registry` | Every `instance_id` sent to or seen in REDCap, with record ID, date and source | Keep and back up. Do not edit. |
| `<PROJECT>_do_not_push.csv` | `push_registry` | Keys that must never be sent (`instance_id`, `reason`) | Add rows by hand when needed. |
| `<PROJECT>_to_push_<time>.csv` | `push_logs` | Rows that would be sent, with `older_than_latest_in_redcap` | Review before every real push. |
| `<PROJECT>_REDCap_duplicates_<time>.csv` | `push_logs` | Submissions held in more than one REDCap record | Keep the corrected record, delete the other copies. |
| `<PROJECT>_held_back_*_<time>.csv` | `push_logs` | Rows without a key, or sharing a submission date with a REDCap record that has no key | Check by hand. |
| `<PROJECT>_ABORTED_clash_<time>.csv` | `push_logs` | Rows found in REDCap at the final check; nothing was written | Run again. |
| `<PROJECT>_pushed_<time>.csv` | `push_logs` | Rows inserted in that run | Keep as the record of the push. |
| `push_history.csv` | `push_logs` | One line per project per run | Check after each run. Do not keep it open in Excel while the script runs. |

## Frequent questions

**A submission was corrected in ODK Central after it was pushed. Will REDCap be updated?**
No. Existing records are never changed by the push, so make the correction in REDCap.

**A record was deleted in REDCap by mistake. How can it be sent again?**
The push blocks it on purpose. Either recreate it by hand in REDCap, or remove its line from the project's registry file and run the push once with `use_redcap_log = FALSE` (the registry already holds every other deleted record, so only that one is offered again). Set `use_redcap_log` back to `TRUE` afterwards.

**Why are all the status dots red on the REDCap record dashboard?**
The push does not send form status, so REDCap marks imported records as Incomplete. The data are there.

**Can the push run from another computer?**
Yes. Copy the repository and the whole `push_registry` folder, and set up `.Renviron` on that computer with that user's own tokens.

**The console shows "The following named parsers don't match the column names: NA".**
A harmless warning from REDCapR when every column is read as text.

**R says it could not find a function such as `read_csv`.**
Part of the script was run without the lines that load the packages. Run the whole script from the top.
