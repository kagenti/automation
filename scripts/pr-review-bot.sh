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
