## Program: PR Review Bot (kagenti org)

**Authority:** Review PRs labeled `ready-for-ai-review`, post review comments
**Trigger:** Every ~15 minutes via OpenClaw cron
**Model:** azure/gpt-5.3-codex
**Identity:** clawgenti (single identity, no switching)
**Approval gate:** None. Comments only, never blocks merge.
**Branding:** "Clawgenti Code Review" (may change to "Rossoclaw Review")
**Tracking:** kagenti/kagenti#1910

### Scope
- Repositories: kagenti/kagenti, kagenti/kagenti-extensions (initial rollout)
- Only open PRs with the `ready-for-ai-review` label
- Uses the `github:pr-review` skill (hardened per PR #1898)

### Behavior

**Review verdicts:**
- Issues found: post comment with inline findings (must-fix, suggestion, nit). Label stays so bot re-reviews after new commits are pushed.
- No issues: post comment with clear verdict: "Clawgenti Code Review: No issues found. Ready for human review."

**Label management:** None. Humans add/remove all labels.
- `ready-for-ai-review` — author adds when ready for AI pass; removes to opt out
- `ready-for-human-review` — human adds after reading AI verdict

**Skip logic:**
- Skip draft PRs
- Skip PRs authored by clawgenti (no self-review)
- Skip PRs already approved (reviewDecision == APPROVED)
- Skip PRs where no new commits exist since last bot review (detected via `<!-- reviewed: SHA -->` HTML comment in bot's last review comment)
- If PR has new commits since last review, re-review

**Human control:**
- Remove `ready-for-ai-review` at any time to stop AI reviews
- Re-add label to request another pass after changes

### What NOT to Do
- Do not submit REQUEST_CHANGES or APPROVE reviews (COMMENT type only)
- Do not add or remove labels
- Do not merge or close PRs
- Do not review clawgenti's own PRs

### Components

**Discovery script** (`~/workspaces/clawgenti/scripts/pr-review-bot.sh`):
- Deterministic bash; iterates repos, filters by label/author/SHA
- Outputs JSON queue of eligible PRs

**Cron job** (`pr-review-bot`):
- `agentTurn` message to clawgenti
- Runs discovery script, then reviews each eligible PR using `github:pr-review` skill
- Posts review comment with `<!-- reviewed: <SHA> -->` footer

### Comment Format

```markdown
## Clawgenti Code Review

<findings from github:pr-review skill>

---
*Reviewed by clawgenti using github:pr-review*
<!-- reviewed: <head-SHA> -->
```

### Permissions
- Repos are public; no collaborator/triage role needed
- clawgenti PAT with `repo` scope (already configured)
- Only permission exercised: posting PR review comments via API

### Security Considerations
- Skill includes supply-chain hardening (PR #1898): flags PRs touching `.claude/`, `.vscode/` configs
- Read-only analysis; no code from reviewed PRs is executed
- PAT never exposed in comments or logs

### Error Handling
- Zero eligible PRs: report and exit cleanly
- Review failure mid-queue: report which PRs succeeded/failed; failed PRs lack SHA marker and retry next cycle
- Timeout: 1200s (20 min)

### Schedule
- Cron job: `pr-review-bot` (every 15 minutes, isolated session)
- Manual run: `openclaw cron run pr-review-bot`
- No conflict with existing jobs (lightweight comment-only API usage)
