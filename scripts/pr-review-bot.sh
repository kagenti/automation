#!/usr/bin/env bash
set -euo pipefail

# PR Review Bot — Discovery Script
# Finds PRs labeled "ready-for-ai-review" that need review.
# Outputs a JSON array of eligible PRs to stdout.

# --- Load shared library ---
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/program-lib.sh"

# --- Configuration ---
BOT_USER="clawgenti"
REPOS=("kagenti/kagenti" "kagenti/kagenti-extensions")
LABEL="ready-for-ai-review"
REVIEW_MARKER="<!-- reviewed:"

# --- CLI args ---
VERBOSE=false
SHOW_HELP=false

while [[ $# -gt 0 ]]; do
  case $1 in
    --verbose) VERBOSE=true; shift ;;
    --help|-h) SHOW_HELP=true; shift ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

if [ "$SHOW_HELP" = true ]; then
  cat << 'USAGE'
pr-review-bot -- Discover PRs needing AI review

USAGE:
  pr-review-bot.sh [OPTIONS]

OPTIONS:
  --verbose         Print diagnostic output to stderr
  --help, -h        Show this help

OUTPUT:
  JSON array of eligible PRs to stdout:
  [{"repo": "kagenti/kagenti", "number": 123, "head_sha": "abc123"}]

PREREQUISITES:
  gh (authenticated as clawgenti), jq
USAGE
  exit 0
fi

# --- Workspace setup ---
setup_workspace "pr-review-bot"
TMPDIR="$PROGRAM_TMPDIR"

# --- Step 1: List labeled PRs across target repos ---
QUEUE_FILE="$TMPDIR/queue.json"
echo "[]" > "$QUEUE_FILE"

for repo in "${REPOS[@]}"; do
  [ "$VERBOSE" = true ] && echo "Checking $repo..." >&2

  prs_json=$(gh pr list --repo "$repo" \
    --label "$LABEL" \
    --state open \
    --json number,author,headRefOid \
    2>/dev/null || echo "[]")

  # Filter out bot's own PRs
  filtered=$(echo "$prs_json" | jq -c \
    --arg bot "$BOT_USER" \
    '[.[] | select(.author.login != $bot)]')

  count=$(echo "$filtered" | jq 'length')
  [ "$VERBOSE" = true ] && echo "  Found $count candidate PR(s) (after filtering self)" >&2

  # Add repo field to each PR
  echo "$filtered" | jq -c \
    --arg repo "$repo" \
    '.[] | {repo: $repo, number: .number, head_sha: .headRefOid}' \
    >> "$TMPDIR/candidates.jsonl"
done
