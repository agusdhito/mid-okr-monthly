#!/usr/bin/env ruby
# OKR KR (L1 row 11) — "Total Time to review on Bitbucket PR <= 2 days".
#
# Measures YOUR latency as a reviewer: the clock starts when you were ADDED as a
# reviewer on the PR and stops at your first approve/reject (L3 also counts a
# comment — see levels.<L>.review_stop_events in config.yml). Weekends are
# excluded; a "day" is 24 business hours.
#
# By default only PRs you were explicitly asked to review are counted. Reviews
# you did without being asked have no request timestamp, so they are skipped
# unless --include-unrequested is passed, which counts them from PR creation.
#
# Usage: ruby review_time.rb <start_date> <end_date> [flags]
#   --level=L1|L3    target + stop-event rules (default L1)
#   --stop-events=a,b  override the level's stop events (approve,reject,comment)
#                      without changing its target -- e.g. count comments at the
#                      L1 2-day target: --stop-events=approve,reject,comment
#   --include-unrequested  also count PRs you were never formally asked to
#                      review; those are clocked from PR creation instead
#   --all            every reviewer in the scanned repos, not just you
#   --repos=a,b      override the config repo list
#   --json           machine-readable output
require_relative 'bb_prs'

START_DATE, END_DATE = require_range(ARGV, 'review_time.rb')
LEVEL, LEVEL_CFG = level_config(ARGV)
TARGET_DAYS = LEVEL_CFG['review_time_target_days'].to_f
KNOWN_STOP_KINDS = %i[approve reject comment].freeze
STOP_OVERRIDE = flag_value(ARGV, 'stop-events')
STOP_KINDS = (STOP_OVERRIDE&.split(',') || Array(LEVEL_CFG['review_stop_events']))
             .map { |k| k.to_s.strip.downcase }.reject(&:empty?).uniq.map(&:to_sym)
if STOP_KINDS.empty?
  abort "--stop-events needs at least one of: #{KNOWN_STOP_KINDS.join(', ')}"
end
unless (bad = STOP_KINDS - KNOWN_STOP_KINDS).empty?
  abort "Unknown stop event(s): #{bad.join(', ')}\n" \
        "  valid: #{KNOWN_STOP_KINDS.join(', ')} (review_events emits only these)"
end
INCLUDE_UNREQUESTED = flag?(ARGV, 'include-unrequested')
ALL = flag?(ARGV, 'all')
REPOS = repos_from(ARGV)

window = (START_DATE..END_DATE)
me = my_display_name
reviews = []

REPOS.each do |repo|
  progress "Scanning PRs in #{repo}"
  prs = scan_prs(repo, START_DATE, END_DATE)
  candidates = prs.reject { |pr| pr[:author] == me && !ALL }
  candidates = candidates.select { |pr| participant?(pr, me) } unless ALL
  progress "  #{prs.size} PR(s) touched, #{candidates.size} to inspect"
  candidates.each do |pr|
    next if pr[:created_at].nil?
    events, requests = review_activity(pr)
    events = events.select { |e| e[:user] == me } unless ALL
    events.group_by { |e| e[:user] }.each do |user, list|
      stop = list.select { |e| STOP_KINDS.include?(e[:kind]) }
                 .select { |e| window.cover?(e[:at].to_date) }
                 .min_by { |e| e[:at] }
      next unless stop
      # Multiple entries mean the user was removed and re-added; the first ask
      # is what their latency should be measured against.
      asks = requests[user]
      requested_at = asks&.first
      next if requested_at.nil? && !INCLUDE_UNREQUESTED
      clock_start = requested_at || pr[:created_at]
      # Reviewing before being asked isn't negative latency — it's zero.
      early = stop[:at] < clock_start
      hours = early ? 0.0 : business_hours(clock_start, stop[:at])
      reviews << {
        repo: repo, id: pr[:id], title: pr[:title], url: pr[:url],
        pr_author: pr[:author], reviewer: user, kind: stop[:kind],
        created_at: pr[:created_at], reviewed_at: stop[:at],
        requested_at: requested_at, requested: !requested_at.nil?,
        request_count: asks&.size.to_i, reviewed_before_request: early,
        clock_start: clock_start,
        wait_days: (hours / 24.0).round(2)
      }
    end
  end
end

def stats(list)
  waits = list.map { |r| r[:wait_days] }
  return nil if waits.empty?
  { count: waits.size,
    mean: (waits.sum / waits.size).round(2),
    median: median(waits),
    worst: waits.max,
    requested: list.count { |r| r[:requested] },
    within_target: list.count { |r| r[:wait_days] <= TARGET_DAYS } }
end

if flag?(ARGV, 'json')
  require 'json'
  overall = ALL ? nil : stats(reviews)
  puts JSON.pretty_generate(
    kr: 'Total time to review on Bitbucket PR',
    level: LEVEL, target_days: TARGET_DAYS,
    stop_events: STOP_KINDS, stop_events_overridden: !STOP_OVERRIDE.nil?,
    period: [START_DATE.to_s, END_DATE.to_s],
    repos: REPOS, reviewer_scope: ALL ? 'all' : me,
    clock: 'reviewer requested -> first stop event',
    include_unrequested: INCLUDE_UNREQUESTED,
    summary: overall,
    by_reviewer: reviews.group_by { |r| r[:reviewer] }.map { |n, l| [n, stats(l)] }.to_h,
    reviews: reviews
  )
  exit
end

puts "## PR review time — #{START_DATE} to #{END_DATE} (#{LEVEL}, target <= #{TARGET_DAYS} days)"
puts
override_note = STOP_OVERRIDE.nil? ? '' : " (stop events overridden, #{LEVEL} default was " \
  "#{Array(LEVEL_CFG['review_stop_events']).join('/')})"
scope_note = INCLUDE_UNREQUESTED ?
  'includes PRs you were never asked to review (clocked from PR creation)' :
  'only PRs you were explicitly asked to review'
puts "_Clock: reviewer requested -> first #{STOP_KINDS.join('/')}#{override_note}. Business hours only " \
     "(weekends excluded); 1 day = 24 business hours._"
puts
puts "_Scope: #{scope_note}. Repos: #{REPOS.join(', ')}._"
puts

if reviews.empty?
  puts "_No reviews by #{ALL ? 'anyone' : me} landed in this period across the scanned repos" \
       "#{INCLUDE_UNREQUESTED ? '' : ' where a review was formally requested — try --include-unrequested'}._"
  exit
end

puts '| Reviewer | Reviews | Requested | Mean days | Median days | Worst | Within target | Verdict |'
puts '|---|---|---|---|---|---|---|---|'
reviews.group_by { |r| r[:reviewer] }.sort_by { |n, _| n.to_s.downcase }.each do |name, list|
  s = stats(list)
  verdict = s[:mean] <= TARGET_DAYS ? 'PASS' : 'MISS'
  marker = name == me ? ' *' : ''
  puts "| #{name}#{marker} | #{s[:count]} | #{s[:requested]}/#{s[:count]} | #{s[:mean]} | " \
       "#{s[:median]} | #{s[:worst]} | #{s[:within_target]}/#{s[:count]} | #{verdict} |"
end
puts

mine = ALL ? reviews.select { |r| r[:reviewer] == me } : reviews
s = stats(mine)
if s
  puts "### Your headline value (#{me})"
  puts
  puts "- **Mean wait: #{s[:mean]} days** (median #{s[:median]}, worst #{s[:worst]})"
  puts "- #{s[:within_target]} of #{s[:count]} reviews within the #{TARGET_DAYS}-day target"
  puts "- Paste **#{s[:mean]}** into the Month-N Value cell — #{s[:mean] <= TARGET_DAYS ? 'on target' : 'off target'}"
  puts
  puts '### Evidence'
  puts
  mine.sort_by { |r| -r[:wait_days] }.each do |r|
    flag = r[:wait_days] > TARGET_DAYS ? ' ⚠️' : ''
    notes = []
    if r[:requested]
      lag = business_hours(r[:created_at], r[:requested_at]) / 24.0
      notes << "asked #{lag.round(2)}d after creation" if lag >= 0.01
      notes << "re-asked #{r[:request_count] - 1}x" if r[:request_count] > 1
      notes << 'reviewed before being asked' if r[:reviewed_before_request]
    else
      notes << 'never asked, clocked from creation'
    end
    suffix = notes.empty? ? '' : " [#{notes.join('; ')}]"
    puts "- [#{r[:repo]} ##{r[:id]}](#{r[:url]}) — #{r[:wait_days]}d (#{r[:kind]}) — " \
         "by #{r[:pr_author]}, created #{r[:created_at].strftime('%Y-%m-%d %H:%M')}, " \
         "reviewed #{r[:reviewed_at].strftime('%Y-%m-%d %H:%M')}#{suffix}#{flag}"
  end
end
