## Program: Link Health (kagenti org)

**Authority:** Scan repos for broken links, create/update GitHub issues, write reports, update docs/link-health.md
**Trigger:** Scanner Mon/Wed/Fri 6am ET (enforced via cron job `link-health-scanner`)
**Approval gate:** None for issues or report updates.
**Escalation:**
  - More than 20 new broken links in a single scan: alert owner
  - Lychee fails on a repo (network, auth): log and continue with remaining repos
  - GitHub API rate limit hit: stop issue creation, report partial results

### Scope
- All repositories in the kagenti GitHub org (cloned at `~/kagenti/`)
- Only documentation files: markdown (.md), HTML, and config files with URLs
- Uses existing .lychee.toml in each repo when present; falls back to default config

### What NOT to Do
- Do not modify source code files
- Do not close issues without evidence the link is fixed (re-scan confirmation)
- Do not create duplicate issues (check for existing issue with same repo + file + URL)
- Do not scan non-default branches

### Operational Notes
- Cron job: `link-health-scanner` (Mon/Wed/Fri 6am ET, isolated)
- Reports: `reports/link-scan/latest.json` and `reports/link-scan/history.json`
- Dashboard: `docs/link-health.md` in kagenti/kagenti (via `link-health/reports` branch PR)
- Labels: `broken-link/internal`, `broken-link/external`, `broken-link/unfixable`
- Manual run: `openclaw cron run link-health-scanner`
- Epic: kagenti/kagenti#1178
