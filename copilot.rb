#!/usr/bin/env ruby
# Copilot PR usage from Bitbucket: % of merged PRs with [FULL_COPILOT]/[PARTIAL_COPILOT] markers.
# Usage: ruby copilot.rb 2026-06
#        ruby copilot.rb 2026-06-01 2026-06-30
# Flags: --repos=talenta-core,talenta-lms-be   subset of config repos
require_relative 'common'

start_date, end_date = parse_range(ARGV)
repos = (flag_value(ARGV, 'repos')&.split(',') || CONFIG.dig('bitbucket', 'copilot_repos'))
me = my_display_name

FULL_RE = /FULL[\s_\-]*COPILOT/i
PARTIAL_RE = /PARTIAL[\s_\-]*COPILOT/i
REVERT_RE = /\Arevert/i

prs = []
repos.each do |repo|
  progress "Scanning merged PRs in #{repo}"
  q = %(state="MERGED" AND created_on>="#{start_date}T00:00:00+00:00" AND created_on<"#{end_date + 1}T00:00:00+00:00")
  bitbucket_each("https://api.bitbucket.org/2.0/repositories/#{BB_WORKSPACE}/#{repo}/pullrequests",
                 { q: q, pagelen: 50,
                   fields: 'next,values.id,values.title,values.author.display_name,values.created_on,values.links.html.href' }) do |pr|
    title = pr['title'].to_s
    kind = if title =~ PARTIAL_RE then :partial
           elsif title =~ FULL_RE then :full
           else :none
           end
    prs << { repo: repo, id: pr['id'], title: title,
             author: pr.dig('author', 'display_name') || 'unknown',
             url: pr.dig('links', 'html', 'href'),
             kind: kind, revert: title =~ REVERT_RE ? true : false }
  end
end

# Reverts inherit the original title's marker; exclude them from the ratio.
counted = prs.reject { |p| p[:revert] }
reverts = prs.count { |p| p[:revert] }

puts "## Copilot PR usage — #{start_date} to #{end_date}"
puts
puts "_Repos scanned: #{repos.join(', ')}. Merged PRs only; #{reverts} revert PR(s) excluded from ratios._"
puts
puts '| Author | Total PRs | Full Copilot | Partial Copilot | No marker | % Full+Partial |'
puts '|---|---|---|---|---|---|'
counted.group_by { |p| p[:author] }.sort_by { |name, _| name.downcase }.each do |name, list|
  full = list.count { |p| p[:kind] == :full }
  partial = list.count { |p| p[:kind] == :partial }
  none = list.count { |p| p[:kind] == :none }
  pct = ((full + partial).to_f / list.size * 100).round(1)
  marker = name == me ? ' ⭐' : ''
  puts "| #{name}#{marker} | #{list.size} | #{full} | #{partial} | #{none} | #{pct}% |"
end
puts

mine = counted.select { |p| p[:author] == me }
puts "## Your PRs (#{me}) — evidence"
puts
if mine.empty?
  puts "_No merged PRs authored by #{me} in this period._"
else
  mine.each do |p|
    label = { full: 'FULL', partial: 'PARTIAL', none: 'no marker' }[p[:kind]]
    puts "- [#{p[:repo]} ##{p[:id]}](#{p[:url]}) — #{p[:title]} — **#{label}**"
  end
  unmarked = mine.count { |p| p[:kind] == :none }
  puts
  puts "_⚠️ #{unmarked} of your PRs have no Copilot marker — if any actually used Copilot, fix the title convention going forward._" if unmarked.positive?
end
