# =====================================================================
# Helpers for reading ODK Central CSV exports
# Functions only: nothing runs when this file is sourced.
# =====================================================================

# -------------------------
# Read an ODK Central CSV export
# -------------------------
# - every column is read as text, so codes and IDs are never turned into numbers
# - empty cells become NA, so coalesce() and is.na() work as expected
# - long group-path headers, e.g. "grp_consent-grp_id-participant_code",
#   are shortened to the field name "participant_code"; files exported with
#   "Remove group names" already have short headers and are left as they are
# - GPS sub-columns keep their parent name with a dot, e.g. "gps.Latitude"
# - "meta-instanceID" becomes "instanceID", "meta-instanceName" becomes "instanceName"
read_odk_csv <- function(path) {
  if (!file.exists(path)) stop("File not found: ", path)            # stop early with a clear message
  df <- utils::read.csv(path,
                        colClasses  = "character",                   # all columns as text
                        na.strings  = c("", "NA"),                   # empty cells -> NA
                        check.names = FALSE,                         # keep the headers exactly as exported
                        encoding    = "UTF-8")                       # accents in names and notes
  original <- names(df)                                              # headers as they are in the file
  parts    <- strsplit(original, "-", fixed = TRUE)                  # split each header on "-"
  short    <- vapply(parts, function(p) {
    last <- p[length(p)]                                             # last piece = field name
    if (last %in% c("Latitude", "Longitude", "Altitude", "Accuracy") && length(p) >= 2) {
      paste(p[length(p) - 1], last, sep = ".")                       # gps-Latitude -> gps.Latitude
    } else {
      last
    }
  }, character(1))
  clash <- duplicated(short) | duplicated(short, fromLast = TRUE)    # same field name used in two groups
  short[clash] <- make.names(original[clash])                        # those keep their full path
  names(df) <- short
  message(basename(path), ": ", nrow(df), " submissions, ", ncol(df), " columns")
  df
}

# -------------------------
# Permanent ODK submission key
# -------------------------
# ODK Central's KEY column is the permanent ID of a submission: it stays the
# same if the submission is later edited in ODK Central, while instanceID
# changes with every edit. KEY is what goes into the REDCap field instance_id,
# and it is how the push recognises a submission that was already sent.
# For submissions never edited in ODK, KEY and instanceID are identical.
add_submission_key <- function(df) {
  if (!"KEY" %in% names(df)) df$KEY <- NA_character_                 # some exports have no KEY column
  df$submission_key <- dplyr::coalesce(df$KEY, df$instanceID)        # KEY first, instanceID if KEY is empty
  n_dup <- sum(duplicated(df$submission_key, incomparables = NA))    # the key must be unique in the export
  if (n_dup > 0) warning(n_dup, " duplicated submission keys in the export; the push keeps the first of each")
  df
}
