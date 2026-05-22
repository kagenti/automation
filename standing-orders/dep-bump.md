## Program: Dep Bump (kagenti org)

**Authority:** Scan repos for stale Dependabot PRs, create/close GitHub issues, write reports
**Trigger:** Scanner Tue/Thu 7am ET (enforced via cron job `dep-bump-scanner`)
**Approval gate:** None for issues or report updates.
**Escalation:**
  - More than 5 new stale PRs in a single scan: alert owner
  - Critical severity (CVSS 9.0+) SLA breach: immediate alert
  - GitHub API rate limit hit: stop issue creation, report partial results

### Scope
- All repositories in the kagenti GitHub org (cloned at `~/kagenti/`)
- Only open Dependabot PRs (state=open, author=app/dependabot)
- Coverage audit of .github/dependabot.yml vs detected ecosystems

### What NOT to Do
- Do not merge or close Dependabot PRs
- Do not modify dependabot.yml files
- Do not create duplicate issues (check for existing issue with same repo + package)
- Do not create issues for PRs within their SLA window

### Operational Notes
- Cron job: `dep-bump-scanner` (Tue/Thu 7am ET, isolated)
- Reports: `reports/dep-bump/latest.json` and `reports/dep-bump/history.json`
- Labels: `dep-bump/stale`
- Manual run: `openclaw cron run dep-bump-scanner`
- Epic: kagenti/kagenti#1260
