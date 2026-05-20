# OpenClaw Program Template

A **program** is a pair of automated scripts (scanner + fixer) that detect problems across the kagenti GitHub org, create issues for them, and resolve them via PRs or comments.

```
Scanner (cheap model, frequent)  -->  GitHub Issues  -->  Fixer (expensive model, less frequent)
        |                               (handoff)                |
        v                                                        v
     Reports                                               PRs / Comments
```

This document defines the contracts a program must follow so that the shared infrastructure (cron, delivery, reports, standing orders) works consistently.

---

## 1. Directory Layout

```
automation/                         # kagenti/automation repo (source of truth)
├── scripts/
│   ├── <program>-scanner.sh        # Scanner script
│   └── <program>-fixer.sh          # Fixer script
├── skills/
│   └── <program>/
│       └── SKILL.md                # OpenClaw skill (technique reference for the agent)
├── standing-orders/
│   └── <program>.md                # Standing order (authority, scope, escalation)
└── docs/
    └── program-template.md         # This file

# On the remote host (~/workspaces/clawgenti/):
scripts/                            # Deployed from automation repo
reports/<program>/                  # Runtime data (not versioned)
├── latest.json                     # Most recent scan results (overwritten each run)
├── history.json                    # Append-only trend data (capped at 500 rows)
└── <program-specific>.json         # Optional auxiliary files (e.g., fixer-ambiguous.json)
```

Shared repo mirrors live at `~/kagenti/` on the remote host, updated nightly by a separate cron job. Programs read from these -- they do not clone repos themselves.

---

## 2. Scanner Contract

### CLI Interface

```
bash <program>-scanner.sh [OPTIONS]

Options:
  --dry-run           Scan and report, but do not create/close issues or push dashboards
  --issue-limit N     Create at most N new issues (0 = unlimited, default)
```

### Execution Flow

1. **Configure** -- read env vars (`REPOS_DIR`, `REPORTS_DIR`), parse CLI args, generate scan ID
2. **Scan** -- iterate over repos, run detection tool, collect findings into a JSONL temp file
3. **Diff** -- compare current findings against `latest.json` from previous scan
   - Key: a composite of fields that uniquely identify a finding (e.g., `repo|file|url`)
   - Sets: NEW (current only), FIXED (previous only), RECURRING (both)
4. **Create issues** -- for each NEW finding, check for existing issue (dedup), then create if none exists
5. **Close issues** -- for each FIXED finding, close its issue with a verification comment
6. **Write reports** -- overwrite `latest.json`, append to `history.json`
7. **Update dashboard** -- generate markdown, commit to a branch, push (fork-based)
8. **Escalation check** -- if new findings exceed threshold, emit alert instead of normal summary

### Report Schema

**latest.json** (overwritten each scan):

```json
{
  "scan_id": "YYYY-MM-DD-NNN",
  "date": "ISO8601",
  "duration_seconds": 202,
  "model": "script",
  "repos_scanned": 13,
  "repos_failed": 0,
  "total_items_checked": 5000,
  "<findings_key>": [
    {
      "repo": "kagenti/adk",
      "<program-specific fields>": "...",
      "category": "<program-defined classification>",
      "issue_number": null,
      "first_detected": "YYYY-MM-DD"
    }
  ],
  "delta": {
    "new": 3,
    "fixed": 1,
    "recurring": 5
  }
}
```

**history.json** (append-only, capped at `MAX_HISTORY_ROWS` -- default 500):

```json
[
  {
    "scan_id": "YYYY-MM-DD-NNN",
    "date": "ISO8601",
    "repos_scanned": 13,
    "total_items_checked": 5000,
    "<program-specific counts>": 0,
    "new": 3,
    "fixed": 1,
    "issues_created": 2,
    "issues_closed": 1
  }
]
```

### Scan ID Format

`YYYY-MM-DD-NNN` where NNN is a zero-padded sequence number for that day (allows multiple scans per day). Derive from `history.json` entries matching today's date.

### Diff Logic

```bash
sort_key() {
  jq -r '[.field1, .field2, .field3] | join("|")' | sort
}

# Generate sorted key files from current and previous findings
jq -c '.' "$CURRENT_FILE" | sort_key > "$TMPDIR/current_keys.txt"
jq -c '.' "$PREV_FILE"    | sort_key > "$TMPDIR/prev_keys.txt"

# Set operations
comm -23 current prev  # NEW
comm -13 current prev  # FIXED
comm -12 current prev  # RECURRING
```

### Deduplication

Before creating an issue, search for an existing open issue:

```bash
existing=$(gh issue list --repo "$repo" \
  --search "<unique title fragment>" \
  --state open --json number --jq '.[0].number' 2>/dev/null || echo "")

if [ -n "$existing" ] && [ "$existing" != "null" ]; then
  # Already exists, skip
fi
```

### Stdout Summary

The scanner prints structured progress to stdout (consumed by the cron delivery system):

```
=== <Program> Scan <scan_id> ===
Repos dir: ...
Mode: DRY RUN / Issue limit: N  (if applicable)
  [per-repo progress]
=== Scan complete ===
Repos scanned: N (failed: N)
Total items: N, Total findings: N
Delta: +N new, -N fixed, N recurring
Issues created: N, Issues closed: N
Duration: Ns
```

---

## 3. Fixer Contract

### CLI Interface

```
bash <program>-fixer.sh [OPTIONS]

Options:
  --dry-run           Re-verify and analyze, but do not create PRs (default)
  --live              Create PRs and push branches
  --issue-limit N     Process at most N issues (default: 5; 0 = unlimited)
  --verbose           Print additional diagnostic output
```

### Execution Flow

1. **Gather issues** -- query all open scanner-created issues across repos
2. **Parse and classify** -- extract structured fields from issue body, separate by category
3. **Re-verify** -- check if the problem still exists
   - If resolved: close the issue with a verification comment
   - If still broken: proceed to fix attempt
4. **Attempt fix** -- apply deterministic resolution logic
   - If unambiguous: record the fix
   - If ambiguous (multiple candidates): write to auxiliary file for model reasoning
5. **Apply fixes** -- group by repo, create fork-based PRs (or preview in dry-run)
6. **Handle remaining categories** -- analyze items that require different treatment (e.g., comments instead of PRs)
7. **Summary** -- print stats

### PR Deduplication

Before processing any issue, check if a fix PR already exists:

```bash
issue_has_open_pr() {
  local repo="$1" issue_number="$2"
  local pr_count
  pr_count=$(gh pr list --repo "$repo" --author "$FORK_OWNER" --state open \
    --search "Closes #$issue_number" --json number --jq 'length' 2>/dev/null || echo "0")
  [ "$pr_count" -gt 0 ]
}
```

Issues with existing open PRs are skipped and do NOT count toward `--issue-limit`.

### Fork-Based PR Workflow

```bash
# 1. Fork on demand
if ! gh repo view "$FORK_OWNER/$repo_name" &>/dev/null; then
  gh repo fork "$ORG/$repo_name" --org "$FORK_OWNER" --clone=false
  sleep 5  # Wait for fork to propagate
fi

# 2. Add fork remote
git remote add "$FORK_REMOTE" "https://github.com/$FORK_OWNER/$repo_name.git" 2>/dev/null || true

# 3. Create fix branch
git checkout -B "$FIX_BRANCH" origin/main

# 4. Apply changes, commit with DCO sign-off
git add <files>
git commit -s -m "<commit message>"

# 5. Push to fork
git push "$FORK_REMOTE" "$FIX_BRANCH" --force-with-lease

# 6. Create cross-fork PR
gh pr create --repo "$ORG/$repo_name" \
  --head "$FORK_OWNER:$FIX_BRANCH" --base main \
  --title "<title>" --body "<body>"

# 7. Comment on each issue linked to the PR
gh issue comment "$issue_number" --repo "$ORG/$repo_name" \
  --body "Fix submitted: $pr_url ..."
```

### Close-Before-Verify Pattern

When closing an issue, always check the exit code before claiming success:

```bash
if gh issue close "$number" --repo "$repo" \
  --comment "Verified as fixed. Auto-closing." 2>/dev/null; then
  echo "  Issue closed"
else
  echo "  WARN: Failed to close issue #$number"
fi
```

### Ambiguous Case Routing

When deterministic logic finds multiple valid candidates, write the item to an auxiliary JSON file (`fixer-ambiguous.json`) for model-assisted resolution on the next cron trigger:

```json
[
  {
    "issue_number": 123,
    "repo": "kagenti/adk",
    "broken_url": "...",
    "reason": "multiple_candidates",
    "candidates": ["path/a.md", "path/b.md"]
  }
]
```

The cron message instructs the model to read this file and resolve items using its judgment.

---

## 4. Handoff Format (GitHub Issues)

Issues are the handoff mechanism between scanner and fixer. The issue body encodes structured metadata that the fixer parses.

### Issue Title

```
:bug: <Summary> in <file>: <identifier>
```

The title must be unique enough for deduplication via `gh issue list --search`.

### Issue Body Template

```markdown
## Describe the bug

<One-line description of the problem detected by automated scan.>

**Repo:** kagenti/<repo_name>
**File:** <relative/path/to/file>
**<Problem-specific field>:** <value>
**<Status/severity field>:** <value>
**First detected:** <YYYY-MM-DD>
**Scan ID:** <scan_id>

## Steps To Reproduce

1. <Actionable reproduction step>
2. <Step>
3. Observe <symptom>

## Expected Behavior

<What should happen instead.>

## Additional Context

Category: <program-defined category>
Detected by: OpenClaw <Program Name> (cron: <cron-job-name>)
```

### Parsing Convention

The fixer extracts fields using grep:

```bash
issue_repo=$(echo "$body" | grep -oP '\*\*Repo:\*\*\s*\K.*' | head -1 | tr -d ' ')
issue_file=$(echo "$body" | grep -oP '\*\*File:\*\*\s*\K.*' | head -1 | tr -d ' ')
```

### Why Not Labels?

The bot account (`clawgenti`) lacks write access for label management on most repos. Category information is encoded in the issue body and parsed by the fixer. Labels are used only when pre-created by org admins (e.g., `broken-link/internal`).

### Query Convention

The fixer finds its issues by searching for the title pattern:

```bash
gh issue list --repo "$repo" \
  --search "<title keyword> in:title" \
  --state open --limit 100 \
  --json number,title,body
```

---

## 5. Cron Job Configuration

### Model Selection

| Role | Model | Rationale |
|------|-------|-----------|
| Scanner | Cheap (e.g., `gemini-2.5-flash`) | Reads script output, creates issues. Minimal reasoning needed. |
| Fixer | Expensive (e.g., `aws/claude-sonnet-4-6`) | Resolves ambiguous cases, reads changelogs, generates migration guidance. |

Model IDs must include the full provider prefix (e.g., `litellm-kagenti-auto/aws/claude-sonnet-4-6`). Without the prefix, the gateway falls back to the default model from the base provider.

### Cron Job Schema (jobs.json)

```json
{
  "id": "<uuid>",
  "name": "<program>-scanner",
  "schedule": "0 11 * * 1,3,5",
  "agent": "clawgenti",
  "payload": {
    "message": "Run the <program> scanner: bash ~/workspaces/clawgenti/scripts/<program>-scanner.sh",
    "model": "litellm-kagenti-auto/<model-id>",
    "isolated": true,
    "timeoutSeconds": 600,
    "delivery": {
      "discord": {
        "channelId": "<channel-id>",
        "account": "<discord-account>"
      }
    }
  }
}
```

### Key Configuration Notes

- `isolated: true` -- each run gets a fresh session (no memory bleed between runs)
- `timeoutSeconds` -- inside `payload`, not at the top level. Gateway caches this at startup; restart required for changes.
- Scanner timeout: 300-600s (depends on number of repos and scan tool speed)
- Fixer timeout: 600-900s (depends on issue count and API calls per issue)
- Scripts are read from disk on each trigger -- no restart needed for script changes
- Gateway restart IS needed for `jobs.json` changes

### Scheduling Guidelines

- Scanner: 2-3x/week (e.g., Mon/Wed/Fri morning UTC)
- Fixer: 1-2x/week (e.g., Tue/Thu afternoon UTC)
- Offset scanner and fixer by at least 24h so issues exist before fixer runs
- Fixer runs after scanner to pick up fresh issues

### Delivery

Cron results are delivered to Discord. Each program shares the same channel unless explicitly separated. The delivery account must be configured in `openclaw.json` under `discord.accounts`.

---

## 6. Standing Order Template

Each program gets a file in `standing-orders/<program>.md`:

```markdown
## Program: <Name> (<scope>)

**Authority:** <What the agent is authorized to do>
**Trigger:** <Schedule and cron job name>
**Approval gate:** <What requires human approval, or "None">
**Escalation:**
  - <Condition>: <action>
  - <Condition>: <action>

### Scope
- <What repos/files/resources are covered>
- <Inclusion/exclusion rules>

### What NOT to Do
- <Explicit prohibitions>

### Operational Notes
- Cron job: `<name>` (<schedule>)
- Reports: `reports/<program>/`
- Manual run: `openclaw cron run <job-name>`
- Epic: kagenti/kagenti#<number>
```

---

## 7. Skill Template

Each program gets a skill at `skills/<program>/SKILL.md`:

```markdown
---
name: <program>_scanner
description: <One-line description of what the skill does>
metadata: {"openclaw": {"requires": {"bins": ["<tool1>", "gh", "jq"]}}}
---

# <Program Name>

<Brief description of the program's purpose.>

## Repo Location
<Where repos live, how they're updated>

## Running <Tool>
<How to invoke the detection tool, with code examples>

## Parsing Output
<How to interpret the tool's output format>

## Diffing Against Previous Scan
<Reference to the diff logic>

## Creating GitHub Issues
<Issue creation with deduplication, using the body template>

## Closing Fixed Issues
<Close logic with verification>

## Writing Reports
<Report schemas for latest.json and history.json>

## Escalation
<When and how to escalate>
```

---

## 8. Checklist for Adding a New Program

1. Write scanner script following Section 2 contracts
2. Write fixer script following Section 3 contracts
3. Create skill file (Section 7)
4. Create standing order (Section 6)
5. Run `shellcheck` on both scripts
6. Test with `--dry-run` locally or on remote host
7. Deploy scripts to remote host: `scp scripts/<name>.sh kagenti-bot:~/workspaces/clawgenti/scripts/`
8. Create `reports/<program>/` directory on remote host
9. Register cron jobs in `~/.openclaw/cron/jobs.json` (restart gateway after)
10. Verify cron delivery end-to-end (Discord)
11. Commit all files to `kagenti/automation` repo
