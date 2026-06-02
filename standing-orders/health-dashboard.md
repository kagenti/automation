## Program: Automation Health Dashboard (kagenti org)

**Authority:** Generate executive-facing dashboard combining all automation program metrics
**Trigger:** Daily 1pm ET (enforced via cron job `health-dashboard`)
**Approval gate:** None for dashboard updates.
**Escalation:** None (read-only aggregator)

### Scope
- Reads reports from all automation programs (link-health, dep-bump)
- Generates `docs/automation-health.md` in kagenti/kagenti
- Pushes via standing fork-based PR (branch: `automation/health-dashboard`)

### What NOT to Do
- Do not modify any program's report files
- Do not create issues or PRs beyond the standing dashboard PR
- Do not run scanners or fixers — dashboard is read-only

### Operational Notes
- Cron job: `health-dashboard` (daily 1pm ET / 17:00 UTC, isolated)
- Output: `docs/automation-health.md` in standing PR
- Fork branch: `automation/health-dashboard`
- Manual run: `openclaw cron run health-dashboard`

### Schedule Coordination
All cron jobs maintain 1h+ separation to avoid crowding Discord:
- Link-health scanner: Mon/Wed/Fri 11:00 UTC (7am ET)
- Link-health fixer: Tue/Thu 12:00 UTC (8am ET)
- Dep-bump scanner: Tue/Thu 14:00 UTC (10am ET)
- Dep-bump fixer: Tue/Thu 16:00 UTC (12pm ET)
- Health dashboard: Daily 17:00 UTC (1pm ET)

### Epic
- kagenti/kagenti#1260
