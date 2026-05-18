#!/usr/bin/env bash
set -euo pipefail

# =============================================================================
# Link Health Scanner — kagenti org
# Scans all repos for broken links, creates/closes GitHub issues, writes reports.
#
# Usage:
#   bash link-health-scanner.sh                  # full run
#   bash link-health-scanner.sh --dry-run        # scan + report, no issues/PRs
#   bash link-health-scanner.sh --issue-limit 3  # create at most 3 issues
#   bash link-health-scanner.sh --dry-run --issue-limit 3  # combined
# =============================================================================

# --- CLI args ---
DRY_RUN=false
ISSUE_LIMIT=0  # 0 = unlimited

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    --issue-limit) ISSUE_LIMIT="$2"; shift 2 ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# --- Configuration ---
REPOS_DIR="${REPOS_DIR:-$HOME/kagenti}"
REPORTS_DIR="${REPORTS_DIR:-$HOME/workspaces/clawgenti/reports/link-scan}"
KAGENTI_REPO="$REPOS_DIR/kagenti"
FORK_REMOTE="clawgenti-kagenti-fork"
FORK_OWNER="clawgenti"
SCAN_DATE=$(date -u +"%Y-%m-%d")
SCAN_TIME=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
MAX_HISTORY_ROWS=500
ESCALATION_THRESHOLD=20

# Determine scan_id (YYYY-MM-DD-NNN)
if [ -f "$REPORTS_DIR/history.json" ]; then
  LAST_SEQ=$(jq -r "[.[] | select(.scan_id | startswith(\"$SCAN_DATE\"))] | length" "$REPORTS_DIR/history.json")
else
  LAST_SEQ=0
fi
SCAN_ID=$(printf "%s-%03d" "$SCAN_DATE" $((LAST_SEQ + 1)))

echo "=== Link Health Scan $SCAN_ID ==="
echo "Repos dir: $REPOS_DIR"
echo "Reports dir: $REPORTS_DIR"
if [ "$DRY_RUN" = true ]; then echo "Mode: DRY RUN (no issues, no PRs)"; fi
if [ "$ISSUE_LIMIT" -gt 0 ]; then echo "Issue limit: $ISSUE_LIMIT"; fi

# --- Ensure reports dir exists ---
mkdir -p "$REPORTS_DIR"

# --- Temp workspace ---
TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

# --- Scan all repos ---
TOTAL_LINKS=0
TOTAL_ERRORS=0
REPOS_SCANNED=0
REPOS_FAILED=0

# Collect all broken links into a single JSONL file
: > "$TMPDIR/broken.jsonl"

for repo_dir in "$REPOS_DIR"/*/ "$REPOS_DIR"/.github/; do
  [ -d "$repo_dir" ] || continue
  repo_name=$(basename "$repo_dir")

  # Skip hidden dirs (except .github) and non-git dirs
  if [[ "$repo_name" == .* && "$repo_name" != ".github" ]] || [ ! -d "$repo_dir/.git" ]; then
    continue
  fi

  echo "Scanning $repo_name..."

  LYCHEE_OUTPUT="$TMPDIR/lychee_${repo_name}.json"

  # Run lychee -- scanner-level args applied to all repos
  LYCHEE_SCANNER_ARGS=(
    --format json
    --scheme http --scheme https
    --exclude 'localhost' --exclude '127\.0\.0\.1' --exclude 'localtest\.me'
    --exclude 'example\.com' --exclude 'example\.org'
    --exclude-all-private
    --exclude-path 'node_modules' --exclude-path 'vendor' --exclude-path '\.claude'
    --accept '200,204,206,403,429,503'
    --timeout 10
    --max-retries 2
    --max-concurrency 8
  )

  if [ -f "$repo_dir/.lychee.toml" ]; then
    lychee "${LYCHEE_SCANNER_ARGS[@]}" --config "$repo_dir/.lychee.toml" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  else
    lychee "${LYCHEE_SCANNER_ARGS[@]}" "$repo_dir" > "$LYCHEE_OUTPUT" 2>/dev/null || true
  fi

  if [ ! -s "$LYCHEE_OUTPUT" ]; then
    echo "  WARN: lychee produced no output for $repo_name"
    REPOS_FAILED=$((REPOS_FAILED + 1))
    continue
  fi

  # Parse results
  repo_total=$(jq '.total // 0' "$LYCHEE_OUTPUT")
  repo_errors=$(jq '.errors // 0' "$LYCHEE_OUTPUT")
  TOTAL_LINKS=$((TOTAL_LINKS + repo_total))
  TOTAL_ERRORS=$((TOTAL_ERRORS + repo_errors))
  REPOS_SCANNED=$((REPOS_SCANNED + 1))

  # Extract broken links from error_map (skip non-URL entries like "Error building URL")
  jq -r --arg repo "$repo_name" --arg repos_dir "$REPOS_DIR/$repo_name/" '
    .error_map // {} | to_entries[] |
    .key as $filepath |
    .value[] |
    select(.url | test("^https?://")) |
    {
      repo: ("kagenti/" + $repo),
      file: ($filepath | ltrimstr($repos_dir) | ltrimstr("./")),
      url: .url,
      status: (.status.code // .status.text // "unknown"),
      category: (
        if (.url | test("github\\.com/kagenti")) then "internal"
        else "external"
        end
      )
    }
  ' "$LYCHEE_OUTPUT" >> "$TMPDIR/broken.jsonl" 2>/dev/null || true

  echo "  Links: $repo_total, Errors: $repo_errors"
done

echo ""
echo "=== Scan complete ==="
echo "Repos scanned: $REPOS_SCANNED (failed: $REPOS_FAILED)"
echo "Total links: $TOTAL_LINKS, Total errors: $TOTAL_ERRORS"

# --- Load previous scan for diffing ---
PREV_BROKEN="$TMPDIR/prev_broken.jsonl"
if [ -f "$REPORTS_DIR/latest.json" ]; then
  jq -c '.broken[]?' "$REPORTS_DIR/latest.json" > "$PREV_BROKEN" 2>/dev/null || true
else
  : > "$PREV_BROKEN"
fi

# --- Compute diff ---
# Key = repo|file|url
sort_key() {
  jq -r '[.repo, .file, .url] | join("|")' | sort
}

# Current keys
jq -c '.' "$TMPDIR/broken.jsonl" | sort_key > "$TMPDIR/current_keys.txt"

# Previous keys
jq -c '.' "$PREV_BROKEN" | sort_key > "$TMPDIR/prev_keys.txt"

# New = in current but not in previous
NEW_LINKS=$(comm -23 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" | wc -l | tr -d ' ')
# Fixed = in previous but not in current
FIXED_LINKS=$(comm -13 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" | wc -l | tr -d ' ')
# Recurring = in both
RECURRING_LINKS=$(comm -12 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" | wc -l | tr -d ' ')

echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"

# --- Count by category ---
BROKEN_INTERNAL=$(jq -s '[.[] | select(.category == "internal")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)
BROKEN_EXTERNAL=$(jq -s '[.[] | select(.category == "external")] | length' "$TMPDIR/broken.jsonl" 2>/dev/null || echo 0)

# --- Create GitHub issues for NEW broken links ---
ISSUES_CREATED=0

# Get new keys
comm -23 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" > "$TMPDIR/new_keys.txt"

while IFS='|' read -r issue_repo issue_file issue_url; do
  [ -z "$issue_repo" ] && continue

  # Check issue limit
  if [ "$ISSUE_LIMIT" -gt 0 ] && [ "$ISSUES_CREATED" -ge "$ISSUE_LIMIT" ]; then
    echo "  SKIP (issue limit $ISSUE_LIMIT reached): $issue_file:$issue_url"
    continue
  fi

  # Get the full broken link record
  link_record=$(jq -c "select(.repo == \"$issue_repo\" and .file == \"$issue_file\" and .url == \"$issue_url\")" "$TMPDIR/broken.jsonl" | head -1)
  [ -z "$link_record" ] && continue

  link_status=$(echo "$link_record" | jq -r '.status')
  link_category=$(echo "$link_record" | jq -r '.category')
  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  # Check for existing issue
  existing=$(gh issue list --repo "$issue_repo" \
    --label "$category_label" \
    --search "Broken link in $issue_file: $issue_url" \
    --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -n "$existing" ] && [ "$existing" != "null" ]; then
    echo "  Issue #$existing already exists for $issue_file:$issue_url"
    continue
  fi

  # Create issue
  issue_title=":bug: Broken link in $issue_file: $issue_url"
  # Truncate title if too long (GitHub limit is 256)
  if [ ${#issue_title} -gt 250 ]; then
    issue_title="${issue_title:0:247}..."
  fi

  # Build verification note for ambiguous status codes
  verify_note=""
  case "$link_status" in
    *403*) verify_note="
> **Note:** This URL returned 403 (Forbidden). Some sites block automated scanners. The link may be valid when accessed from a browser. Please verify manually before fixing." ;;
    *503*) verify_note="
> **Note:** This URL returned 503 (Service Unavailable), which may indicate a temporarily unavailable service rather than a permanently broken link. Please verify manually before fixing." ;;
    *429*) verify_note="
> **Note:** This URL returned 429 (Too Many Requests). The link may be valid but rate-limited. Please verify manually before fixing." ;;
  esac

  issue_body="## Describe the bug

Broken link detected by automated link health scan.

**Repo:** $issue_repo
**File:** $issue_file
**Broken URL:** $issue_url
**HTTP Status:** $link_status
**First detected:** $SCAN_DATE
**Scan ID:** $SCAN_ID
$verify_note
## Steps To Reproduce

1. Open https://github.com/$issue_repo/blob/main/$issue_file
2. Click or follow the link to \`$issue_url\`
3. Observe $link_status error

## Expected Behavior

The link should resolve to valid documentation.

## Additional Context

Category: $link_category
Detected by: OpenClaw Link Health Scanner (cron: link-health-scanner)"

  if [ "$DRY_RUN" = true ]; then
    echo "  [DRY RUN] Would create issue on $issue_repo: $issue_file:$issue_url ($link_category)"
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
  elif gh issue create --repo "$issue_repo" \
    --title "$issue_title" \
    --label "kind/bug,$category_label" \
    --body "$issue_body" 2>/dev/null; then
    ISSUES_CREATED=$((ISSUES_CREATED + 1))
    echo "  Created issue for $issue_file:$issue_url"
  else
    echo "  WARN: Failed to create issue for $issue_file:$issue_url"
  fi

  # Rate limit: small delay between issue creations
  sleep 1
done < "$TMPDIR/new_keys.txt"

echo "Issues created: $ISSUES_CREATED"

# --- Close issues for FIXED links ---
ISSUES_CLOSED=0

comm -13 "$TMPDIR/current_keys.txt" "$TMPDIR/prev_keys.txt" > "$TMPDIR/fixed_keys.txt"

while IFS='|' read -r fix_repo fix_file fix_url; do
  [ -z "$fix_repo" ] && continue

  # Get the category from the previous scan
  link_record=$(jq -c "select(.repo == \"$fix_repo\" and .file == \"$fix_file\" and .url == \"$fix_url\")" "$PREV_BROKEN" | head -1)
  link_category=$(echo "$link_record" | jq -r '.category // "internal"')

  if [ "$link_category" = "internal" ]; then
    category_label="broken-link/internal"
  else
    category_label="broken-link/external"
  fi

  issue_number=$(gh issue list --repo "$fix_repo" \
    --label "$category_label" \
    --search "Broken link in $fix_file: $fix_url" \
    --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

  if [ -n "$issue_number" ] && [ "$issue_number" != "null" ]; then
    if [ "$DRY_RUN" = true ]; then
      echo "  [DRY RUN] Would close issue #$issue_number for $fix_file:$fix_url"
      ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
    elif gh issue close "$issue_number" --repo "$fix_repo" \
      --comment "Link verified as fixed in scan $SCAN_ID ($SCAN_DATE). Auto-closing." 2>/dev/null; then
      ISSUES_CLOSED=$((ISSUES_CLOSED + 1))
      echo "  Closed issue #$issue_number for $fix_file:$fix_url"
    fi
  fi
done < "$TMPDIR/fixed_keys.txt"

echo "Issues closed: $ISSUES_CLOSED"

# --- Write latest.json ---
BROKEN_ARRAY=$(jq -s '
  [.[] | . + {
    issue_number: null,
    first_detected: "'"$SCAN_DATE"'",
    context: ""
  }]
' "$TMPDIR/broken.jsonl" 2>/dev/null || echo "[]")

cat > "$REPORTS_DIR/latest.json" << LATEST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "duration_seconds": $SECONDS,
  "model": "script",
  "repos_scanned": $REPOS_SCANNED,
  "repos_failed": $REPOS_FAILED,
  "total_links_checked": $TOTAL_LINKS,
  "broken": $BROKEN_ARRAY,
  "delta": {
    "new": $NEW_LINKS,
    "fixed": $FIXED_LINKS,
    "recurring": $RECURRING_LINKS
  }
}
LATEST_EOF

echo "Wrote latest.json"

# --- Append to history.json ---
HISTORY_ROW=$(cat << HIST_EOF
{
  "scan_id": "$SCAN_ID",
  "date": "$SCAN_TIME",
  "repos_scanned": $REPOS_SCANNED,
  "total_links_checked": $TOTAL_LINKS,
  "broken_internal": $BROKEN_INTERNAL,
  "broken_external": $BROKEN_EXTERNAL,
  "new": $NEW_LINKS,
  "fixed": $FIXED_LINKS,
  "issues_created": $ISSUES_CREATED,
  "issues_closed": $ISSUES_CLOSED
}
HIST_EOF
)

if [ -f "$REPORTS_DIR/history.json" ] && [ -s "$REPORTS_DIR/history.json" ]; then
  jq --argjson row "$HISTORY_ROW" '. + [$row] | if length > '"$MAX_HISTORY_ROWS"' then .[-'"$MAX_HISTORY_ROWS"':] else . end' \
    "$REPORTS_DIR/history.json" > "$TMPDIR/history_new.json"
  mv "$TMPDIR/history_new.json" "$REPORTS_DIR/history.json"
else
  echo "[$HISTORY_ROW]" > "$REPORTS_DIR/history.json"
fi

echo "Appended to history.json"

# --- Update docs/link-health.md ---
# Build trend table from last 10 history entries
TREND_TABLE=$(jq -r '
  .[-10:] | reverse | .[] |
  "| \(.date | split("T")[0] | split("-")[1:] | join("-")) | \(.broken_internal) | \(.broken_external) | \(if .new > .fixed then "+\(.new - .fixed)" elif .new < .fixed then "\(.new - .fixed)" else "0" end) |"
' "$REPORTS_DIR/history.json" 2>/dev/null || echo "| - | - | - | - |")

# Build per-repo breakdown
REPO_TABLE=$(jq -rs '
  group_by(.repo) | .[] |
  (.[0].repo | split("/")[1]) as $name |
  ([.[] | select(.category == "internal")] | length) as $int |
  ([.[] | select(.category == "external")] | length) as $ext |
  "| \($name) | \($int) | \($ext) | |"
' "$TMPDIR/broken.jsonl" 2>/dev/null || echo "| - | - | - | |")

SCAN_TIME_ET=$(TZ="America/New_York" date +"%Y-%m-%d %H:%M ET")

cat > "$TMPDIR/link-health.md" << DASHBOARD_EOF
# Link Health Report

> Last scan: $SCAN_TIME_ET | Scan ID: $SCAN_ID

## Summary

| Metric | Value |
|--------|-------|
| Repos scanned | $REPOS_SCANNED |
| Total links checked | $TOTAL_LINKS |
| Broken (internal) | $BROKEN_INTERNAL |
| Broken (external) | $BROKEN_EXTERNAL |
| New since last scan | +$NEW_LINKS |
| Fixed since last scan | -$FIXED_LINKS |

## Trend (last 10 scans)

| Date | Internal | External | Delta |
|------|----------|----------|-------|
$TREND_TABLE

## Broken Links by Repo

| Repo | Internal | External | Issues |
|------|----------|----------|--------|
$REPO_TABLE

---
*Generated by OpenClaw Link Health Scanner. Do not edit manually.*
DASHBOARD_EOF

# Commit and push dashboard
if [ "$DRY_RUN" = true ]; then
  echo "[DRY RUN] Would push docs/link-health.md to fork and create/update cross-fork PR"
  echo "[DRY RUN] Dashboard preview:"
  cat "$TMPDIR/link-health.md"
else
  cd "$KAGENTI_REPO"

  # Ensure fork remote exists
  if ! git remote get-url "$FORK_REMOTE" &>/dev/null; then
    git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/kagenti.git"
  fi

  # Fetch fork's branch if it exists, otherwise create from main
  if git fetch "$FORK_REMOTE" link-health/reports 2>/dev/null; then
    git checkout -B link-health/reports "$FORK_REMOTE/link-health/reports"
  else
    git fetch "$FORK_REMOTE" main 2>/dev/null || true
    git checkout -B link-health/reports "$FORK_REMOTE/main" 2>/dev/null \
      || git checkout -B link-health/reports
  fi

  mkdir -p docs
  cp "$TMPDIR/link-health.md" docs/link-health.md
  git add docs/link-health.md
  git commit -s -m "docs: Update link health dashboard ($SCAN_ID)" 2>/dev/null || echo "No changes to commit"
  git push "$FORK_REMOTE" link-health/reports 2>/dev/null || echo "WARN: Failed to push dashboard to fork"

  # Create or update standing cross-fork PR
  existing_pr=$(gh api "repos/kagenti/kagenti/pulls?head=$FORK_OWNER:link-health/reports&state=open" \
    --jq '.[0].number' 2>/dev/null || echo "")

  if [ -z "$existing_pr" ] || [ "$existing_pr" = "null" ]; then
    gh pr create --repo kagenti/kagenti \
      --head "$FORK_OWNER:link-health/reports" --base main \
      --title "docs: Link health dashboard (auto-updated)" \
      --body "Auto-updated by OpenClaw Link Health Scanner. This PR is continuously updated with each scan. Merge when convenient." 2>/dev/null || echo "WARN: Failed to create dashboard PR"
  fi
fi

echo "Dashboard updated"

# --- Escalation check ---
if [ "$NEW_LINKS" -gt "$ESCALATION_THRESHOLD" ]; then
  echo ""
  echo "ALERT: Link health scan found $NEW_LINKS new broken links (threshold: $ESCALATION_THRESHOLD)."
  echo "This may indicate a bulk documentation change or a widespread external service outage."
  echo "Review issues at https://github.com/kagenti/kagenti/issues?q=label:broken-link"
fi

# --- Summary ---
echo ""
echo "=== Scan $SCAN_ID Summary ==="
echo "Repos: $REPOS_SCANNED scanned, $REPOS_FAILED failed"
echo "Links: $TOTAL_LINKS checked, $((BROKEN_INTERNAL + BROKEN_EXTERNAL)) broken ($BROKEN_INTERNAL internal, $BROKEN_EXTERNAL external)"
echo "Delta: +$NEW_LINKS new, -$FIXED_LINKS fixed, $RECURRING_LINKS recurring"
echo "Issues: $ISSUES_CREATED created, $ISSUES_CLOSED closed"
echo "Duration: ${SECONDS}s"
