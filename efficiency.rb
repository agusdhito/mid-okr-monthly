#!/usr/bin/env ruby
# OKR KR (L1 row 12) — "Total efficiency score per week >= 2.25".
#
#   score(week) = artifacts(week) / 5
#   artifacts   = PRs created + PRs reviewed + docs created/updated
#                 + oncall tickets moved to Done
#
# The divider is a flat 5 (days in a working week), including a partial first or
# last week -- a week you only half-worked scores half, which is the point.
# --prorate restores the old behaviour of dividing by the working days of that
# week that actually fall inside the requested period.
#
# Usage: ruby efficiency.rb <start_date> <end_date> [flags]
#   --level=L1|L3     target + which review events count (default L1)
#   --stop-events=a,b override the level's review events (approve,reject,comment)
#   --all             per-person breakdown for the Bitbucket + Jira streams
#   --repos=a,b       override the config repo list
#   --prorate         divide a partial edge week by its in-period working days
#                     instead of 5 (--strict-divider is now the default, kept
#                     as an accepted no-op so old invocations still run)
#   --docs-fast       skip Confluence version history (see caveat below)
#   --json            machine-readable output
require_relative 'bb_prs'

START_DATE, END_DATE = require_range(ARGV, 'efficiency.rb')
LEVEL, LEVEL_CFG = level_config(ARGV)
TARGET = LEVEL_CFG['efficiency_target'].to_f
KNOWN_STOP_KINDS = %i[approve reject comment].freeze
# Row 12 ("was this PR reviewed at all?") is a broader question than row 11
# ("how fast did the review land?"), so it reads its own config key and only
# falls back to review_stop_events when that key is absent.
configured_events = Array(LEVEL_CFG['efficiency_review_events'])
configured_events = Array(LEVEL_CFG['review_stop_events']) if configured_events.empty?
STOP_KINDS = (flag_value(ARGV, 'stop-events')&.split(',') || configured_events)
             .map { |k| k.to_s.strip.downcase }.reject(&:empty?).uniq.map(&:to_sym)
abort "--stop-events needs at least one of: #{KNOWN_STOP_KINDS.join(', ')}" if STOP_KINDS.empty?
unless (bad = STOP_KINDS - KNOWN_STOP_KINDS).empty?
  abort "Unknown review event(s): #{bad.join(', ')}\n" \
        "  valid: #{KNOWN_STOP_KINDS.join(', ')} (review_events emits only these)"
end
ALL = flag?(ARGV, 'all')
# Dividing by 5 is the default now; --strict-divider is accepted and ignored so
# existing scripted invocations keep working.
PRORATE = flag?(ARGV, 'prorate') || flag?(ARGV, 'prorate_divider') || flag?(ARGV, 'prorate-divider')
DOCS_FAST = flag?(ARGV, 'docs-fast') || flag?(ARGV, 'docs_fast')
REPOS = repos_from(ARGV)

window = (START_DATE..END_DATE)
me = my_display_name
WEEKS = weeks_in(START_DATE, END_DATE)

# person => week => {pr_created:, pr_reviewed:, docs:, oncall:}
tally = {}
def bump(tally, person, week, stream, n = 1)
  tally[person] ||= {}
  tally[person][week] ||= { pr_created: 0, pr_reviewed: 0, docs: 0, oncall: 0 }
  tally[person][week][stream] += n
end
evidence = { pr_created: [], pr_reviewed: [], docs: [], oncall: [] }

# --- Stream 1 + 2: Bitbucket PRs created and reviewed ------------------------
REPOS.each do |repo|
  progress "Scanning PRs in #{repo}"
  prs = scan_prs(repo, START_DATE, END_DATE)
  prs.each do |pr|
    next if pr[:created_at].nil?
    if window.cover?(pr[:created_at].to_date) && (ALL || pr[:author] == me)
      bump(tally, pr[:author], week_key(pr[:created_at]), :pr_created)
      evidence[:pr_created] << { person: pr[:author], week: week_key(pr[:created_at]),
                                 label: "#{repo} ##{pr[:id]} — #{pr[:title]}", url: pr[:url] }
    end
    next unless ALL || participant?(pr, me)
    events = review_events(pr)
    events = events.select { |e| e[:user] == me } unless ALL
    events.select { |e| STOP_KINDS.include?(e[:kind]) }
          .select { |e| window.cover?(e[:at].to_date) }
          .group_by { |e| [e[:user], week_key(e[:at])] }
          .each do |(user, wk), _list|
      bump(tally, user, wk, :pr_reviewed)
      evidence[:pr_reviewed] << { person: user, week: wk,
                                  label: "#{repo} ##{pr[:id]} — #{pr[:title]}", url: pr[:url] }
    end
  end
end

# --- Stream 3: Confluence docs created/updated (current user only) ----------
# CQL can only filter on a page's LAST modification, so per-week attribution
# comes from each page's version history (one extra call per page). --docs-fast
# skips that and buckets every page into the week of its latest edit, which
# undercounts a page you touched in several different weeks.
progress 'Querying Confluence docs'
cql = render_template(CONFIG.dig('confluence', 'docs_cql'),
                      'start' => START_DATE, 'end' => END_DATE)
pages = confluence_search(cql)
docs_failed = pages.nil?
if docs_failed
  pages = []
  warn "[warn] Confluence search failed — docs stream counted as 0. Most likely the " \
       'ATLASSIAN_CONFLUENCE_TOKEN lacks content/search scope (a token that can read ' \
       'spaces but not pages returns 401 "scope does not match"). Regenerate it with ' \
       'read:page:confluence + search:confluence.'
end
progress "  #{pages.size} page(s) matched"
pages.each do |result|
  content = result['content'] || {}
  id = content['id']
  title = content['title'] || result['title']
  url = "#{CONFLUENCE_BASE}#{result['url']}" if result['url']
  weeks_touched = []
  if id && !DOCS_FAST
    versions = http_get("#{CONFLUENCE_BASE}/rest/api/content/#{id}/version", { limit: 100 }, true)
    (versions && versions['results'] || []).each do |v|
      next unless v.dig('by', 'displayName') == me
      when_at = parse_bb_time(v['when'])
      next if when_at.nil? || !window.cover?(when_at.to_date)
      weeks_touched << week_key(when_at)
    end
  end
  if weeks_touched.empty?
    last = parse_bb_time(result['lastModified'] || content.dig('version', 'when'))
    weeks_touched << week_key(last) if last && window.cover?(last.to_date)
  end
  weeks_touched.uniq.each do |wk|
    bump(tally, me, wk, :docs)
    evidence[:docs] << { person: me, week: wk, label: title, url: url }
  end
end

# --- Stream 4: Jira oncall tickets moved to Done ----------------------------
# Scoped by the oncall board's own saved filter (jira.oncall.filter_id), so the
# count always matches what the board shows. `filter = <id>` runs on the plain
# platform search API — no Jira Software board scope needed.
oncall_cfg = CONFIG.dig('jira', 'oncall') || {}
ONCALL_BOARD = oncall_cfg['board_id']
ONCALL_FILTER = oncall_cfg['filter_id']
oncall_jql_template = oncall_cfg['jql']
# A stream that could not be queried must never be indistinguishable from a
# stream that was queried and found nothing — both render as 0 in the table, so
# the failure is recorded here and banner-ed above the evidence.
oncall_failed = false
if oncall_jql_template.to_s.empty?
  oncall_failed = true
  warn '[warn] jira.oncall.jql is not set in config.yml — oncall stream counted as 0'
elsif oncall_jql_template.include?('{filter}') && ONCALL_FILTER.to_s.empty?
  oncall_failed = true
  warn '[warn] jira.oncall.jql needs {filter} but jira.oncall.filter_id is not set — ' \
       'oncall stream counted as 0. Read the id off the board config; do not guess it.'
else
  WEEKS.each do |wk|
    days = (START_DATE..END_DATE).select { |d| week_key(d) == wk }
    jql = render_template(oncall_jql_template,
                          'project' => oncall_cfg['project'],
                          'filter' => ONCALL_FILTER,
                          'epics' => Array(oncall_cfg['epics']).join(', '),
                          'start' => days.first,
                          'end' => days.last + 1)
    progress "Querying oncall tickets (board #{ONCALL_BOARD} / filter #{ONCALL_FILTER}) for #{wk}"
    issues = jira_search(jql, %w[summary assignee status], true)
    if issues.nil?
      oncall_failed = true
      warn "[warn] oncall JQL failed for #{wk} — check jira.oncall.jql in config.yml:\n        #{jql}"
      next
    end
    issues.each do |issue|
      person = issue.dig('fields', 'assignee', 'displayName') || 'unassigned'
      next unless ALL || person == me
      bump(tally, person, wk, :oncall)
      evidence[:oncall] << { person: person, week: wk,
                             label: "#{issue['key']} — #{issue.dig('fields', 'summary')}",
                             url: "#{JIRA_SITE}/browse/#{issue['key']}" }
    end
  end
end

# --- Scoring ----------------------------------------------------------------
def divider(wk, prorate, start_date, end_date)
  return 5 unless prorate
  d = working_days_in_week(wk, start_date, end_date)
  d.zero? ? 5 : d
end

def score_rows(weeks, person_tally, prorate, start_date, end_date)
  weeks.map do |wk|
    t = person_tally[wk] || { pr_created: 0, pr_reviewed: 0, docs: 0, oncall: 0 }
    artifacts = t.values.sum
    div = divider(wk, prorate, start_date, end_date)
    t.merge(week: wk, artifacts: artifacts, divider: div,
            score: (artifacts.to_f / div).round(2))
  end
end

people = ALL ? tally.keys.sort_by { |p| p.to_s.downcase } : [me]
scored = people.map { |p| [p, score_rows(WEEKS, tally[p] || {}, PRORATE, START_DATE, END_DATE)] }.to_h
averages = scored.map { |p, rows| [p, rows.empty? ? 0.0 : (rows.sum { |r| r[:score] } / rows.size).round(2)] }.to_h

if flag?(ARGV, 'json')
  require 'json'
  puts JSON.pretty_generate(
    kr: 'Total efficiency score per week', level: LEVEL, target: TARGET,
    period: [START_DATE.to_s, END_DATE.to_s], weeks: WEEKS, repos: REPOS,
    scope: ALL ? 'all' : me, divider_mode: PRORATE ? 'prorate' : 'fixed_5',
    review_events: STOP_KINDS,
    oncall_board: ONCALL_BOARD, oncall_filter: ONCALL_FILTER,
    average_score: averages, weekly: scored, evidence: evidence
  )
  exit
end

puts "## Efficiency score — #{START_DATE} to #{END_DATE} (#{LEVEL}, target >= #{TARGET})"
puts
puts '_Artifacts = PRs created + PRs reviewed + Confluence docs created/updated + oncall tickets ' \
     "moved to Done. A PR counts as reviewed on #{STOP_KINDS.join('/')}. Divider = " \
     "#{PRORATE ? 'working days of the week that fall inside the period' : '5 (fixed, including partial edge weeks)'}._"
puts

scored.each do |person, rows|
  puts "### #{person}#{person == me ? ' *' : ''} — average **#{averages[person]}** " \
       "(#{averages[person] >= TARGET ? 'PASS' : 'MISS'} vs #{TARGET})"
  puts
  puts '| Week | PR created | PR reviewed | Docs | Oncall done | Artifacts | ÷ | Score |'
  puts '|---|---|---|---|---|---|---|---|'
  rows.each do |r|
    puts "| #{r[:week]} | #{r[:pr_created]} | #{r[:pr_reviewed]} | #{r[:docs]} | #{r[:oncall]} | " \
         "#{r[:artifacts]} | #{r[:divider]} | #{r[:score]}#{r[:score] < TARGET ? ' ⚠️' : ''} |"
  end
  puts
end

# Streams fail soft (a dead token yields nil, not a crash), so say plainly which
# columns are real zeros and which are unknowns reported as zero.
degraded = []
if docs_failed
  degraded << ['Docs', 'the Confluence token could not search pages (needs ' \
               'read:page:confluence + search:confluence)']
end
if oncall_failed
  degraded << ['Oncall done', "the Jira query against board #{ONCALL_BOARD} / filter " \
               "#{ONCALL_FILTER} failed — check the token and jira.oncall in okr-config.yml"]
end
unless degraded.empty?
  puts "> ⚠️ **#{degraded.size} of 4 artifact streams could not be read.** Those columns are " \
       'unknown, not zero, so every score here is a FLOOR — do not paste it into the OKR cell ' \
       'until they are fixed.'
  degraded.each { |col, why| puts "> - `#{col}` — #{why}" }
  puts
end
puts "_Paste **#{averages[me]}** into the Month-N Value cell._" if averages[me]
puts
puts '_Note: Confluence docs are collected for the current user only — CQL `contributor` ' \
     'cannot be resolved for other people without their account IDs._' if ALL
puts
puts '### Evidence'
puts
%i[pr_created pr_reviewed docs oncall].each do |stream|
  items = evidence[stream].select { |e| ALL || e[:person] == me }
  next if items.empty?
  label = { pr_created: 'PRs created', pr_reviewed: 'PRs reviewed',
            docs: 'Docs created/updated', oncall: 'Oncall tickets done' }[stream]
  puts "**#{label} (#{items.size})**"
  puts
  items.sort_by { |e| e[:week] }.each do |e|
    link = e[:url] ? "[#{e[:label]}](#{e[:url]})" : e[:label]
    puts "- #{e[:week]} — #{link}#{ALL ? " — #{e[:person]}" : ''}"
  end
  puts
end
