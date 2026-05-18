# kagenti/automation

Version-controlled home for kagenti org automation programs (scanner/fixer pattern).

## Structure

```
scripts/           Program scripts (scanner + fixer per program)
skills/            OpenClaw SKILL.md files per program
standing-orders/   Standing order definitions per program
reports/           (gitignored) Runtime data stays on remote host only
```

## Programs

| Program | Scanner | Fixer | Epic |
|---------|---------|-------|------|
| Link Health | `scripts/link-health-scanner.sh` | `scripts/link-health-fixer.sh` | [#1178](https://github.com/kagenti/kagenti/issues/1178) |

## Deploy

Scripts run on the remote host (`kagenti-bot:~/workspaces/clawgenti/scripts/`).
Deploy after merging changes:

```bash
scp scripts/<name>.sh kagenti-bot:~/workspaces/clawgenti/scripts/
```

No gateway restart needed -- scripts are read from disk on each cron trigger.

## Runtime

- Reports: `~/workspaces/clawgenti/reports/<program>/` (remote host only)
- Cron jobs managed via OpenClaw gateway (`~/.openclaw/cron/jobs.json`)
- Bot account: [clawgenti](https://github.com/clawgenti)
