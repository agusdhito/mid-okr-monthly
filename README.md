# okr-monthly — Claude Code skill

Monthly OKR evidence, collected automatically instead of hand-gathered from five
dashboards. Produces a paste-ready pack for the quarterly OKR worksheet per the
[How to OKR runbook](https://jurnal.atlassian.net/wiki/spaces/TALDOC/pages/51129057466/How+to+OKR).

## Coverage

| L1 row | Key Result | Weight | Script |
|---|---|---|---|
| 10 | X% PR Full + Partial (Copilot markers) | 10% | `copilot.rb` |
| 11 | Time to review on Bitbucket PR ≤ 2 days | 20% | `review_time.rb` |
| 12 | Efficiency score per week ≥ 2.25 | 20% | `efficiency.rb` |
| 18 | Median lead time for change ≤ 5 days | 8% | `okr_mltc.rb` |

`evidence.rb` additionally pulls PIC epics, tech debt, TBB production bugs (Jira
JQL) and technical documentation (Confluence CQL) as evidence links.

Not automated — the skill leaves these as a checklist: code coverage (row 15,
needs Code Insights/Sonar/Codecov), documentation coverage (row 16, denominator
undefined), bugs leaked to staging (row 17, no JQL definition), PagerDuty
MTTA/MTTR (rows 8–9), AI-assisted review/RCA (rows 24–25, no machine-readable
marker). 0%-weight rows are out of scope. Automated today: **58%** of the L1
scorecard; ceiling with Jira/Confluence/Bitbucket alone: **88%**.

## Install

Requires Ruby (macOS `/usr/bin/ruby` is fine). No gems, no bundler.

**1. Copy the files**

```bash
mkdir -p ~/scripts/okr-monthly && cp *.rb ~/scripts/okr-monthly/
mkdir -p ~/.claude/skills/okr-monthly && cp SKILL.md README.md ~/.claude/skills/okr-monthly/
```

**2. Create tokens**

| Token | Where | Scopes |
|---|---|---|
| Jira | [id.atlassian.com](https://id.atlassian.com/manage-profile/security/api-tokens) | `read:jira-work`, `read:jira-user` |
| Confluence | same | `read:page:confluence`, `search:confluence` |
| Bitbucket | [bitbucket.org](https://bitbucket.org/account/settings/api-tokens/) | Repositories: Read, Pull requests: Read |

**3. Export them** — required before step 4. Add to `~/.zshrc` to persist:

```bash
export ATLASSIAN_EMAIL="you@mekari.com"
export ATLASSIAN_JIRA_TOKEN="..."
export ATLASSIAN_CONFLUENCE_TOKEN="..."
export BITBUCKET_API_TOKEN="..."
```

One `ATLASSIAN_API_TOKEN` can stand in for all three Atlassian vars. Tokens live
only in the environment — never in `okr-config.yml`, never committed.

**4. Generate the config**

```bash
ruby ~/scripts/okr-monthly/install.rb
```

Asks for: site URL, OKR level (L1/L3), Bitbucket workspace, repo list, MLTC repo
split, oncall board URL, bug project key. Auto-detects `cloud_id`, validates every
repo slug, resolves the oncall board's saved filter, and backs up any existing
config to `okr-config.yml.bak`.

Flags: `--doctor` (probe only, no prompts, no writes) · `--yes` (accept existing
defaults) · `OKR_CONFIG=/path` (non-default config location)

**5. Verify**

```bash
ruby ~/scripts/okr-monthly/install.rb --doctor
```

Exits `0` when all four artifact streams are readable, `1` otherwise. Run this
whenever a stream reports an implausible zero — it probes the exact endpoint each
stream uses, so it catches a token that authenticates but lacks scope.

## Usage

In Claude Code (no argument = previous month):

```
/okr-monthly 2026-06
```

Claude runs the collectors (MLTC takes a few minutes), then writes
`okr-evidence-<YYYY-MM>.md` with values + evidence links mapped to the
worksheet's purple cells, plus the manual-KR checklist.

Standalone, from the install directory:

```bash
# both dates required, Monday->Sunday
ruby efficiency.rb  2026-08-31 2026-09-27
ruby review_time.rb 2026-08-31 2026-09-27 --include-unrequested

# accept either YYYY-MM or a date pair
ruby copilot.rb   2026-06
ruby okr_mltc.rb  2026-06 --all     # CSV rows for every author (shared sheet)
ruby evidence.rb  2026-06
```

Common flags: `--repos=a,b` (all four collectors) · `--level=L1|L3` and `--json`
(efficiency, review_time) · `--all` (efficiency, review_time, okr_mltc).

## Metric definitions

**Row 11 — review time.** Your latency as a reviewer: clock starts when you were
added as a reviewer, stops at your first approve/reject (L3 also counts a
comment; see `levels.<L>.review_stop_events`). Weekends excluded, 1 day = 24
business hours. Population is PRs where that stop event falls inside the period.
PRs you reviewed without being asked have no request timestamp and are skipped
unless `--include-unrequested`, which clocks them from PR creation instead.

**Row 12 — efficiency.** `score(week) = artifacts / 5`, averaged over the
period's ISO weeks — a partial edge week scores partially by design
(`--prorate` divides by that week's in-period working days instead). Artifacts:

1. *PR created* — author = person, `created_on` in week, all states.
2. *PR reviewed* — one per (PR, week) where the person approved/rejected.
3. *Docs created/updated* — one per (page, week), attributed via each page's
   version history. **Current user only** — CQL `contributor` needs an account
   id, so `--all` cannot resolve it for others. `--docs-fast` skips history.
4. *Oncall tickets Done* — Jira `TD` issues under the quarterly
   `[BAU] On Call Tickets` epic (or an `[On-Call]` summary prefix) that
   transitioned to Done that week. **Add the new epic key to
   `jira.oncall.epics` each quarter** — `TD-9824` is 26Q3.

## Caveats

- Copilot counting is fuzzy on typos (`FULL_COPILOTO` still counts as FULL) and
  **excludes revert PRs** from the ratio.
- MLTC dedupes a PR shipped in several deploys to its earliest deploy, and uses
  business hours (24h/day, weekends excluded).
- Bug major/minor split matches priority names against P0/P1/highest/blocker/critical.
