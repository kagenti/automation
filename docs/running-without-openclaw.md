# Running Automation Programs Without OpenClaw

The scanner and fixer scripts are plain bash. They don't depend on OpenClaw -- it's just the trigger and delivery mechanism. You can run them from Claude Code, a cron job, CI, or your terminal.

This guide covers running the link health program standalone. The same pattern applies to any future program in this repo.

---

## Prerequisites

Install these tools on the machine where you'll run the scripts:

| Tool | Purpose | Install |
|------|---------|---------|
| `gh` | GitHub CLI (issues, PRs, forks) | `brew install gh` or [cli.github.com](https://cli.github.com) |
| `lychee` | Link checker | `brew install lychee` or [github.com/lycheeverse/lychee](https://github.com/lycheeverse/lychee) |
| `jq` | JSON processor | `brew install jq` |
| `bash` 4+ | Shell | macOS ships 3.2; use `brew install bash` for 4+ |

Authenticate `gh` with a GitHub account that has:
- Read access to all repos in the target org
- Write access to create issues (scanner)
- Write access to create forks and PRs (fixer)

```bash
gh auth login
gh auth status  # confirm you're authenticated
```

## Setup

### 1. Clone this repo

```bash
git clone git@github.com:kagenti/automation.git
cd automation
```

### 2. Clone target repos

The scripts expect all org repos to live in a single directory. Clone them:

```bash
mkdir -p ~/kagenti
gh repo list kagenti --limit 100 --json name --jq '.[].name' | while read -r repo; do
  if [ ! -d "$HOME/kagenti/$repo" ]; then
    gh repo clone "kagenti/$repo" "$HOME/kagenti/$repo"
  fi
done
```

To keep them fresh (optional -- run before each scan):

```bash
for dir in ~/kagenti/*/; do
  git -C "$dir" pull --ff-only 2>/dev/null || true
done
```

### 3. Create reports directory

```bash
mkdir -p ~/reports/link-scan
```

### 4. Configure environment

```bash
export REPOS_DIR="$HOME/kagenti"
export REPORTS_DIR="$HOME/reports/link-scan"
```

Add these to your shell profile if you want them persistent.

## Running the Scanner

```bash
# Dry run -- scan and report, no issues created
bash scripts/link-health-scanner.sh --dry-run

# Limit issue creation (useful for first runs)
bash scripts/link-health-scanner.sh --issue-limit 5

# Full run -- creates issues, closes fixed ones, updates dashboard
bash scripts/link-health-scanner.sh
```

Output goes to stdout. Reports are written to `$REPORTS_DIR/latest.json` and `$REPORTS_DIR/history.json`.

## Running the Fixer

```bash
# Dry run -- re-verifies issues, shows what it would fix
bash scripts/link-health-fixer.sh --dry-run --issue-limit 5

# Live -- creates PRs for fixable links, comments on external links
bash scripts/link-health-fixer.sh --live

# Verbose -- print extra diagnostics
bash scripts/link-health-fixer.sh --live --verbose
```

The fixer uses `FORK_OWNER="clawgenti"` by default. To use your own account for PRs, edit the `FORK_OWNER` variable at the top of `link-health-fixer.sh`.

The fixer also sets a DCO sign-off identity (`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`). Update these to your own name and email if you're running it under your account.

## Running from Claude Code

Ask Claude to run the scripts directly:

```
Run bash scripts/link-health-scanner.sh --dry-run from the automation repo
```

Or for scheduled runs, use Claude Code's `/loop` feature:

```
/loop 12h Run bash scripts/link-health-scanner.sh from ~/automation
```

Claude Code can also interpret the output and take follow-up actions (e.g., "run the scanner, then if there are new broken links, run the fixer for those repos").

## Running on a Schedule (without OpenClaw)

### System cron

```bash
# Edit your crontab
crontab -e

# Scanner: Mon/Wed/Fri at 11:00 UTC
0 11 * * 1,3,5 cd ~/automation && REPOS_DIR=~/kagenti REPORTS_DIR=~/reports/link-scan bash scripts/link-health-scanner.sh >> ~/logs/scanner.log 2>&1

# Fixer: Tue/Thu at 14:00 UTC
0 14 * * 2,4 cd ~/automation && REPOS_DIR=~/kagenti REPORTS_DIR=~/reports/link-scan bash scripts/link-health-fixer.sh --live >> ~/logs/fixer.log 2>&1
```

### GitHub Actions (CI-based)

You could also run these as scheduled workflows. The scripts just need `gh`, `lychee`, `jq`, and the repos checked out. A workflow would:
1. Checkout all org repos
2. Install lychee
3. Run the scanner/fixer script
4. (Optional) Post results to Slack/Discord via webhook

## What OpenClaw Adds

If you later want the OpenClaw layer back, it provides:
- **Cron triggers** with model-based sessions (the agent reads the script output and can reason about it)
- **Discord delivery** of run summaries
- **Session isolation** (each run gets a fresh context)
- **Timeout management** (kills hung runs)

None of these are required for the scripts to work. They're convenience features for unattended operation.

## Adapting for a Different Org

To run against a different GitHub org:

1. Clone that org's repos into `$REPOS_DIR`
2. Edit `FORK_OWNER` in the fixer (or set it as an env var)
3. Edit `ORG="kagenti"` in the fixer to your org name
4. Update DCO identity in the fixer (`GIT_AUTHOR_NAME` / `GIT_AUTHOR_EMAIL`)
5. Run the scanner -- it will detect broken links and create issues in the target repos
