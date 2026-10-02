---
name: okr-monthly
description: Generate a paste-ready OKR evidence pack for Talenta engineers — Copilot PR %, PR review time, weekly efficiency score, MLTC (DORA lead time), and Jira/Confluence evidence links per the "How to OKR" runbook. Use when the user asks to fill/update their OKR, collect OKR metrics or evidence, or runs /okr-monthly.
---

# okr-monthly

Collects the measurable Key Results from the [How to OKR runbook](https://jurnal.atlassian.net/wiki/spaces/TALDOC/pages/51129057466/How+to+OKR) and assembles a paste-ready evidence pack the engineer copies into their OKR worksheet (the purple **Current Value** and **Hyperlink** cells).

## Step 1 — Resolve the period

`review_time.rb` and `efficiency.rb` **require an explicit start_date AND end_date**
(`2026-07-01 2026-09-30`) — they bucket by ISO week, so a defaulted period would
silently mis-attribute artifacts. Ask for both if the user gave only one.
The older collectors (`copilot.rb`, `evidence.rb`, `okr_mltc.rb`) still
accept a month (`2026-06`) or no argument (previous calendar month).
Confirm the resolved period back to the user in your first message.

## Step 1b — Resolve the level

L1, L2 and L3 have different targets and different scoring rules (L1 and L2 stop the
review clock at approve/reject; L3 also counts a comment). Pass `--level=L1|L2|L3`;
L1 is the default. L2 (efficiency target 3, review ≤ 2 days, MLTC ≤ 4 days) was read
from its own template and is now in `~/scripts/okr-monthly/okr-config.yml`. Any level
still absent from the config makes the scripts abort rather than borrow another
level's numbers. Ask the user which level they are on.

## Step 2 — Check credentials

Auth is **per service** — Atlassian now issues scoped tokens, one per product:

| Env var | Used for |
|---|---|
| `ATLASSIAN_EMAIL` | basic-auth username for all three |
| `ATLASSIAN_JIRA_TOKEN` | Jira |
| `ATLASSIAN_CONFLUENCE_TOKEN` | Confluence |
| `BITBUCKET_API_TOKEN` | Bitbucket |
| `ATLASSIAN_API_TOKEN` | fallback if a dedicated one is unset |

Two things that will otherwise waste a run (both verified 2026-09-09):

- **Scoped tokens are rejected by the site URL.** `https://jurnal.atlassian.net/rest/...`
  returns 401 for a ~192-char scoped token; it must go through the gateway
  (`https://api.atlassian.com/ex/jira/<cloud_id>/rest/...`). `~/scripts/okr-monthly/okr-config.yml`'s
  `jira.cloud_id` drives this — `common.rb` builds the right base automatically.
- **A token can authenticate and still lack scope.** A Confluence token may read
  `/rest/api/space` fine but return `401 "scope does not match"` on
  `/rest/api/search`, which kills the docs stream. `efficiency.rb` prints a loud
  banner and treats the score as a FLOOR instead of reporting a fake 0.

`ruby ~/scripts/okr-monthly/install.rb --doctor` checks both of the above plus every
stream's endpoint, and confirms the Jira and Bitbucket display names match (they
are compared against ONE name, so a mismatch silently drops artifacts). Run it
first whenever a stream reports an implausible zero.

Verify before launching anything:

```bash
source ~/.zshrc
cd ~/scripts/okr-monthly && ruby -r./common -e 'puts "jira: #{(http_get("#{JIRA_BASE}/rest/api/3/myself", nil, true)||{})["displayName"].inspect}";
puts "bitbucket: #{(http_get("https://api.bitbucket.org/2.0/user", nil, true)||{})["display_name"].inspect}";
puts "confluence: #{confluence_search("type = page", 1).nil? ? "NO SEARCH SCOPE" : "ok"}"'
```

Never paste a token into a file, a commit, or chat. If one is exposed, tell the user
to rotate it at https://id.atlassian.com/manage-profile/security/api-tokens.

## Step 3 — Run the collectors (in parallel, background)

All scripts live in `~/scripts/okr-monthly/` and take the same date args. Run all four as background Bash tasks, redirecting stdout to the scratchpad, e.g.:

All collectors live in **`~/scripts/okr-monthly/`** (moved there 2026-09-09; they read
`~/scripts/okr-monthly/okr-config.yml`, overridable with `OKR_CONFIG=`). `~/scripts/mltc.rb` is
the engineer's own standalone script and is NOT part of this set — the skill's port
is `okr_mltc.rb`.

```bash
S=~/scripts/okr-monthly
ruby $S/copilot.rb     <start> <end>                > <scratchpad>/okr-copilot.md      # L1 row 10
ruby $S/review_time.rb <start> <end> --level=L1     > <scratchpad>/okr-review-time.md  # L1 row 11
ruby $S/efficiency.rb  <start> <end> --level=L1     > <scratchpad>/okr-efficiency.md   # L1 row 12
ruby $S/okr_mltc.rb    <start> <end>                > <scratchpad>/okr-mltc.md         # L1 row 18
ruby $S/evidence.rb    <start> <end>                > <scratchpad>/okr-evidence.md
```

Shared flags on the new collectors: `--level=`, `--all` (whole team), `--repos=a,b`,
`--json`. `efficiency.rb` divides by a fixed 5 by default; `--prorate` divides a
partial first/last week by its in-period working days instead (`--strict-divider` is
now the default and accepted as a no-op). It also takes `--stop-events=a,b` (which
review events count as an artifact — default approve,reject,comment) and `--docs-fast`
(skip Confluence version history — undercounts a page edited across several weeks).

- `okr_mltc.rb` is the slow one (walks every production deploy in ~16 repos) — warn the user it can take several minutes.
- `review_time.rb` and `efficiency.rb` fetch PR activity per candidate PR; scanning all
  16 repos for a quarter takes a few minutes. `--all` is much slower — it inspects every
  PR's activity, not just yours.
- **KRs these scripts do NOT cover** (see README): code coverage, technical-documentation
  coverage and leaked-bug counts need conventions the org has not defined yet; the two
  PagerDuty KRs and the two AI-assisted-review KRs cannot be sourced from
  Jira/Confluence/Bitbucket at all. Never invent a value for these — leave the ☐.
- Progress goes to stderr; a non-zero exit with a clear `abort` message usually means token scope or config — relay the message, don't retry blindly.
- `~/scripts/okr-monthly/okr-config.yml` (same folder) holds board id, repo lists, and JQL templates. If a section reports "query failed — adjust config", surface that to the user rather than editing silently.

## Step 4 — Assemble the evidence pack

When all four are done, write `okr-evidence-<YYYY-MM>.md` in the current working directory with this structure. Pull numbers/links from the script outputs; do NOT invent values. Where a KR is manual, keep the ☐ placeholder and its how-to link so the engineer can finish it.

```markdown
# OKR evidence pack — <Name> — <YYYY-MM>

> Paste each row's Current Value + evidence links into the purple cells of your
> OKR worksheet. Runbook: https://jurnal.atlassian.net/wiki/spaces/TALDOC/pages/51129057466

## Automated KRs
| Key Result | Current value (this month) | Evidence |
|---|---|---|
| Avg story points / sprint | <from sprint.md> | <sprint names + issue links> |
| Carry-over % | <from sprint.md> | |
| Bugs (major / minor) | <from sprint.md> | |
| Copilot PR % (full+partial) | <from copilot.md> | <PR links> |
| MLTC (median lead time) | <hours and ≈days from mltc.md> | CSV below for the MLTC Google Sheet |
| PIC initiatives (Epics done) | <count from evidence.md> | <epic links> |
| Tech debt registered/delivered | <count from evidence.md> | <issue links> |
| Production bugs (TBB) | <count from evidence.md> | <issue links> |
| Technical documentation | <count from evidence.md> | <page links> |

### MLTC CSV (paste via Data → Split text to columns)
<csv block from mltc.md>

## Manual KRs — complete these yourself
- ☐ MTTA/MTTR + ack rate (on-call): PagerDuty Integration Service dashboard, filter your on-call schedule
- ☐ Code coverage ≥90%: latest `make test` pipeline per service
- ☐ High-quality PR feedback: pick 2–3 Bitbucket comment threads
- ☐ AI in SDLC + sharing sessions: docs created with AI + https://jurnal.atlassian.net/wiki/spaces/TALDOC/pages/50995396633
- ☐ CFR on PIC initiatives: pipeline + RCA links if any deployment failed
```

## Step 5 — Report

Show the user: the headline numbers (avg SP, carry-over %, Copilot %, MLTC median, doc/epic counts), the path to the pack, and which manual checkboxes remain. If any KR looks off-target for the month (e.g. Copilot % below target), point it out neutrally — the point of monthly runs is catching drift early.
