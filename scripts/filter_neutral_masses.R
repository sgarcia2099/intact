#!/usr/bin/env Rscript

args <- commandArgs(trailingOnly = TRUE)

usage <- function() {
  cat(
    paste(
      "Usage:",
      "  filter_neutral_masses.R --input <table.tsv> --output <filtered.tsv>",
      "    [--ppm <ppm>] [--rt-window <minutes>] [--min-intensity <value>]",
      "    [--min-qscore <value>]",
      sep = "\n"
    )
  )
}

parse_args <- function(args) {
  opts <- list(ppm = 10, rt_window = 0.5, min_intensity = 0, min_qscore = 0.5)
  i <- 1
  while (i <= length(args)) {
    key <- args[[i]]
    if (key %in% c("--help", "-h")) {
      usage()
      quit(save = "no", status = 0)
    }
    if (i == length(args)) {
      stop(sprintf("Missing value for %s", key), call. = FALSE)
    }
    value <- args[[i + 1]]
    if (key == "--input") opts$input <- value
    else if (key == "--output") opts$output <- value
    else if (key == "--ppm") opts$ppm <- as.numeric(value)
    else if (key == "--rt-window") opts$rt_window <- as.numeric(value)
    else if (key == "--min-intensity") opts$min_intensity <- as.numeric(value)
    else if (key == "--min-qscore") opts$min_qscore <- as.numeric(value)
    else stop(sprintf("Unknown argument: %s", key), call. = FALSE)
    i <- i + 2
  }

  if (is.null(opts$input) || is.null(opts$output)) {
    stop("--input and --output are required", call. = FALSE)
  }

  opts
}

ppm_delta <- function(mass, ppm) {
  mass * ppm / 1e6
}

opts <- parse_args(args)
dir.create(dirname(opts$output), recursive = TRUE, showWarnings = FALSE)

tab <- read.delim(opts$input, sep = "\t", header = TRUE, check.names = FALSE, stringsAsFactors = FALSE)
input_rows <- nrow(tab)

required_cols <- c("neutral_mass", "intensity", "retention_time_min")
missing_cols <- setdiff(required_cols, names(tab))
if (length(missing_cols) > 0) {
  stop(sprintf("Missing required columns: %s", paste(missing_cols, collapse = ", ")), call. = FALSE)
}

tab$neutral_mass <- as.numeric(tab$neutral_mass)
tab$intensity <- as.numeric(tab$intensity)
tab$retention_time_min <- as.numeric(tab$retention_time_min)

tab <- tab[!is.na(tab$neutral_mass) & !is.na(tab$intensity) & !is.na(tab$retention_time_min), , drop = FALSE]
tab <- tab[tab$intensity >= opts$min_intensity, , drop = FALSE]
post_prefilter_rows <- nrow(tab)

if (opts$min_qscore > 0 && "quality_score" %in% names(tab)) {
  qs_numeric <- suppressWarnings(as.numeric(tab$quality_score))
  tab <- tab[!is.na(qs_numeric) & qs_numeric >= opts$min_qscore, , drop = FALSE]
}
post_qscore_rows <- nrow(tab)

if (nrow(tab) == 0) {
  message(sprintf("Filtering summary: input=%d, prefilter_kept=0, qscore_kept=0, dedup_kept=0", input_rows))
  write.table(tab, file = opts$output, sep = "\t", quote = FALSE, row.names = FALSE)
  quit(save = "no", status = 0)
}

tab <- tab[order(tab$neutral_mass, tab$retention_time_min, -tab$intensity), , drop = FALSE]

keep <- rep(TRUE, nrow(tab))
for (i in seq_len(nrow(tab))) {
  if (!keep[[i]]) next
  mass_window <- ppm_delta(tab$neutral_mass[[i]], opts$ppm)
  dup_idx <- which(
    keep &
      abs(tab$neutral_mass - tab$neutral_mass[[i]]) <= mass_window &
      abs(tab$retention_time_min - tab$retention_time_min[[i]]) <= opts$rt_window
  )
  if (length(dup_idx) > 1) {
    best <- dup_idx[which.max(tab$intensity[dup_idx])]
    dup_idx <- setdiff(dup_idx, best)
    keep[dup_idx] <- FALSE
  }
}

filtered <- tab[keep, , drop = FALSE]
message(sprintf(
  "Filtering summary: input=%d, prefilter_kept=%d, qscore_kept=%d, dedup_kept=%d",
  input_rows,
  post_prefilter_rows,
  post_qscore_rows,
  nrow(filtered)
))
write.table(filtered, file = opts$output, sep = "\t", quote = FALSE, row.names = FALSE)