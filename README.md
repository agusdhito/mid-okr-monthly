# okr-monthly — Claude Code skill

Monthly OKR evidence, collected automatically instead of hand-gathered from five
dashboards. Produces a paste-ready pack for the quarterly OKR worksheet per the
[How to OKR runbook](https://jurnal.atlassian.net/wiki/spaces/TALDOC/pages/51129057466/How+to+OKR).

## What it automates

| KR | Source |
|---|---|
| Copilot PR % (FULL/PARTIAL title markers) | Bitbucket merged PRs |
| MLTC — median lead time to change (DORA) | Bitbucket pipelines + PRs (replaces the old local `okr_mltc.rb`/`mltc_core.rb` + manual copy-paste) |
| PIC epics, tech debt, TBB production bugs | Jira JQL |
| Technical documentation list | Confluence CQL |

Still manual (the skill leaves you a checklist): PagerDuty MTTA/MTTR, code
coverage, qualitative PR feedback, AI-in-SDLC docs, CFR/RCA links.

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

```bash
source ~/.zshrc
```

**4. Generate the config**

```bash
ruby ~/scripts/okr-monthly/install.rb
```

Asks for: site URL, OKR level (L1/L3), Bitbucket workspace, repo list, MLTC repo
split, oncall board URL, bug project key. Auto-detects `cloud_id`, validates
every repo slug, and resolves the oncall board's saved filter. Backs up any
existing config to `okr-config.yml.bak`.

Flags: `--doctor` (probe only, no prompts, no writes) · `--yes` (accept existing
defaults) · `OKR_CONFIG=/path` (non-default config location)

**5. Verify**

```bash
ruby ~/scripts/okr-monthly/install.rb --doctor
```

Exits `0` when all four artifact streams are readable, `1` otherwise. Run this
whenever a stream reports an implausible zero — it probes the exact endpoint each
stream uses, so it catches a token that authenticates but lacks scope.

**6. Run**

```bash
cd ~/scripts/okr-monthly
ruby efficiency.rb  2026-08-31 2026-09-27      # use Monday->Sunday dates
ruby review_time.rb 2026-08-31 2026-09-27 --include-unrequested
ruby copilot.rb     2026-08-31 2026-09-27
ruby okr_mltc.rb    2026-08-31 2026-09-27
```

## Usage

In Claude Code:

```
/okr-monthly 2026-06
```

No argument = previous month. Claude runs the collectors (MLTC takes a few
minutes), then writes `okr-evidence-<YYYY-MM>.md` with values + evidence links
mapped to the worksheet's purple cells, plus the manual-KR checklist.

Scripts also run standalone without Claude:

```bash
ruby scripts/copilot.rb 2026-06         # Copilot PR table (whole team)
ruby scripts/mltc.rb 2026-06 --all      # MLTC CSV for the shared Google Sheet
ruby scripts/evidence.rb 2026-06        # epics / tech debt / TBB / Confluence docs
```

Handy flags: `--repos=a,b` (copilot, mltc), `--all`
(mltc: CSV rows for every author, e.g. when one person updates the shared sheet).

## Notes & known caveats

- Copilot counting is fuzzy on typos (`FULL_COPILOTO` still counts as FULL) and
  **excludes revert PRs** from the ratio.
- MLTC dedupes a PR shipped in several deploys to its earliest deploy, and uses
  business hours (24h/day, weekends excluded) — same as the original scripts.
- Bug major/minor split matches priority names against P0/P1/highest/blocker/critical.

---

## 2026 OKR template coverage (added 2026-09-09)

Source: `[L1][TEMPLATE][Talenta Integration] OKR 2026 Engineering` (Google Sheet,
single tab `ALL`). Rows below are that sheet's row numbers. The seven KRs weighted
**0%** (story points, carry-over, E2E-as-PIC, CFR, PR-feedback survey, bugs-from-PIC,
tech-debt registration) are excluded — they do not score at L1.

| Row | Key Result | L1 weight | Script | State |
|---|---|---|---|---|
| 10 | X% PR Full + Partial (Copilot markers) | 10% | `copilot.rb` | ✅ live-tested |
| 11 | Total time to review on Bitbucket PR ≤ 2 days | 20% | `review_time.rb` | ✅ live-tested |
| 12 | Total efficiency score per week ≥ 2.25 | 20% | `efficiency.rb` | ⚠️ 3 of 4 streams live; docs stream blocked on Confluence token scope |
| 18 | Median lead time for change ≤ 5 days | 8% | `okr_mltc.rb` | ✅ pre-existing |

`sprint.rb` was deleted 2026-09-11: story points and carry-over are both 0%-weight
rows above, board 153 stopped sprinting after `26Q3 - TD Sprint 1` (ended 2026-07-22),
and it was the only script needing the Jira Software agile scope.
| 15 | Code coverage ≥ 90% | 15% | — | ❌ not a Jira/Confluence/Bitbucket primitive; needs Bitbucket Code Insights or SonarQube/Codecov |
| 16 | 100% technical documentation coverage | 10% | — | ❌ denominator undefined; Postman has no configured API access |
| 17 | Bugs leaked to staging (P0-P1 / P2-P4) | 5% | — | ❌ no JQL for "leaked to staging" + "triggered from development" |
| 8 | 100% incident resolution time on-call | 2% | — | ❌ PagerDuty only |
| 9 | MTTA < 60s, ≥ 80% ack rate | 2% | — | ❌ PagerDuty only |
| 24 | AI-assisted reviews ≥ 70% of SDLC artifacts | 5% | — | ❌ no machine-readable AI marker exists |
| 25 | AI-assisted RCA documented | 3% | — | ❌ same marker problem |

Automatable today: **58%** of the L1 scorecard. Ceiling with these three tools: **88%**,
once coverage / doc-coverage / leaked-bug definitions land.

### Metric definitions actually implemented

**Row 11 — review time.** Population: PRs where you are a participant and your first
approve/reject falls inside the period (the PR itself may be older). Clock starts at PR
`created_on`, stops at that event. Business hours only, weekends excluded, 1 day = 24
business hours. Headline is the mean, with median and worst printed.

> Known bias: starting the clock at `created_on` charges you for time before you were
> added as a reviewer, and for time the PR sat idle awaiting its author. A PR opened in
> July and approved in August reads as a 30-day review. If the org wants review *response*
> time instead, the clock should start at the last source `update` event before the review
> — an `activity` field that is already fetched.

**Row 12 — efficiency.** `score(week) = artifacts / working days`, averaged over the
period's ISO weeks. Divider is 5, or the actual in-period working days for a partial
first/last week (`--strict-divider` forces 5). Artifact streams:

1. *PR created* — Bitbucket, author = person, `created_on` in week, all states.
2. *PR reviewed* — one artifact per (PR, week) where the person approved/rejected.
3. *Docs created/updated* — Confluence pages the person contributed to, one artifact per
   (page, week), attributed via each page's version history rather than the page's single
   `lastmodified` date. **Current user only** — CQL `contributor` needs an account id, so
   `--all` cannot resolve it for other people.
4. *Oncall tickets Done* — Jira `TD` (project id 2521): issues under the quarterly
   `[BAU] On Call Tickets` epic (or with an `[On-Call]` summary prefix) that transitioned
   to Done that week, via `status CHANGED TO "Done" DURING`. **Add the new epic key to
   `jira.oncall.epics` each quarter** — `TD-9824` is 26Q3.
