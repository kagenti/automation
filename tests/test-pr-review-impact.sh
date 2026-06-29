#!/usr/bin/env bash
set -euo pipefail

# Verifies pr-review-impact.sh classification: per-repo activation, aggregation,
# median TTM in HOURS (1-decimal), and that a Dependabot PR clawgenti only
# commented on is excluded.
TEST_TMPDIR=$(mktemp -d)
trap 'rm -rf "$TEST_TMPDIR"' EXIT

# median TTM in hours, rounded to 1 decimal (mirrors the script's median_ttm).
# keep in sync with pr-review-impact.sh (median_ttm and the mk classifier are
# reimplemented here, not sourced, so they can silently drift if edited there).
median_ttm() {
  jq -s '
    [.[] |
      ((.mergedAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime) -
       (.createdAt | strptime("%Y-%m-%dT%H:%M:%SZ") | mktime)) / 3600
    ] | sort | (if length == 0 then 0
    elif length % 2 == 1 then .[length / 2 | floor]
    else (.[length / 2 - 1] + .[length / 2]) / 2
    end) | (. * 10 | round) / 10'
}

# Classify merged PRs the way the script does: against a marked-set and a
# per-repo activation (split on createdAt).
mk() { # $1=activation $2=marked_json  (merged PRs on stdin)
  jq -c --arg act "$1" --argjson marked "$2" \
    '{number:.number, createdAt:.createdAt, mergedAt:.mergedAt,
      reviewed: (.number as $n | ($marked|index($n))!=null),
      after_activation: (if $act=="" then null else (.createdAt >= $act) end)}'
}

# repo A: activation 2026-06-13, marked=[1].
#   #1  reviewed   created 06-12T00 merged 06-13T00 = 24h  (createdAt 06-12<06-13 -> before)
#   #2  unreviewed created 06-06T00 merged 06-10T00 = 96h  (before)
#   #99 DEPENDABOT, clawgenti only COMMENTED (NOT marked) created 06-14T00 merged 06-14T05 = 5h (after, unreviewed)
printf '%s\n' \
  '{"number":1,"createdAt":"2026-06-12T00:00:00Z","mergedAt":"2026-06-13T00:00:00Z"}' \
  '{"number":2,"createdAt":"2026-06-06T00:00:00Z","mergedAt":"2026-06-10T00:00:00Z"}' \
  '{"number":99,"createdAt":"2026-06-14T00:00:00Z","mergedAt":"2026-06-14T05:00:00Z"}' \
  | mk "2026-06-13T00:00:00Z" '[1]' > "$TEST_TMPDIR/all.jsonl"

# repo B: activation 2026-06-16, marked=[1].
#   #1 reviewed created 06-15T00 merged 06-16T12 = 36h (createdAt 06-15<06-16 -> before)
printf '%s\n' \
  '{"number":1,"createdAt":"2026-06-15T00:00:00Z","mergedAt":"2026-06-16T12:00:00Z"}' \
  | mk "2026-06-16T00:00:00Z" '[1]' >> "$TEST_TMPDIR/all.jsonl"

# Expected over both repos:
#   reviewed   = {A#1=24h, B#1=36h} -> median 30.0, count 2
#   unreviewed = {A#2=96h, A#99=5h} -> sorted {5,96} median 50.5, count 2  (exercises 1-decimal)
#   dependabot A#99 must be unreviewed (commented, not marked)
#   after  = {A#99 (06-14>=06-13)} count 1
#   before = {A#1 (06-12<06-13), A#2, B#1 (06-15<06-16)} count 3

reviewed_c=$(jq -c 'select(.reviewed==true)'  "$TEST_TMPDIR/all.jsonl" | jq -s 'length')
unreviewed_c=$(jq -c 'select(.reviewed==false)' "$TEST_TMPDIR/all.jsonl" | jq -s 'length')
dependabot_reviewed=$(jq -c 'select(.number==99 and .reviewed==true)' "$TEST_TMPDIR/all.jsonl" | jq -s 'length')
reviewed_m=$(jq -c 'select(.reviewed==true)'  "$TEST_TMPDIR/all.jsonl" | median_ttm)
unreviewed_m=$(jq -c 'select(.reviewed==false)' "$TEST_TMPDIR/all.jsonl" | median_ttm)
after_c=$(jq -c 'select(.after_activation==true)'  "$TEST_TMPDIR/all.jsonl" | jq -s 'length')
before_c=$(jq -c 'select(.after_activation==false)' "$TEST_TMPDIR/all.jsonl" | jq -s 'length')

fail=0
[ "$reviewed_c" = "2" ]          || { echo "FAIL reviewed count: got $reviewed_c want 2"; fail=1; }
[ "$unreviewed_c" = "2" ]        || { echo "FAIL unreviewed count: got $unreviewed_c want 2"; fail=1; }
[ "$dependabot_reviewed" = "0" ] || { echo "FAIL dependabot PR #99 wrongly counted reviewed"; fail=1; }
[ "$reviewed_m" = "30" ]         || { echo "FAIL reviewed median hours: got $reviewed_m want 30"; fail=1; }
[ "$unreviewed_m" = "50.5" ]     || { echo "FAIL unreviewed median hours: got $unreviewed_m want 50.5"; fail=1; }
[ "$after_c" = "1" ]             || { echo "FAIL after count: got $after_c want 1"; fail=1; }
[ "$before_c" = "3" ]            || { echo "FAIL before count: got $before_c want 3"; fail=1; }
[ "$fail" -eq 0 ] && echo "PASS: segmentation + hours-TTM + dependabot exclusion" || exit 1
