#!/usr/bin/env ruby
# MLTC (Median Lead Time to Change): first commit -> production deployment, in
# business hours (24h/day, weekends excluded). Port of the original
# mltc.rb (services) + mltc_core.rb (monolith tag-PR flow) with env-var creds.
#
# Usage: ruby mltc.rb 2026-06
#        ruby mltc.rb 2026-06-01 2026-06-30
# Flags: --repos=talenta-lms-be,talenta-core   subset (matched against both groups)
#        --all                                 CSV rows for every author, not just you
require_relative 'common'

start_date, end_date = parse_range(ARGV)
mltc_cfg = CONFIG.dig('bitbucket', 'mltc')
repo_filter = flag_value(ARGV, 'repos')&.split(',')
service_repos = mltc_cfg['service_repos'] || []
monolith_repos = mltc_cfg['monolith_repos'] || []
if repo_filter
  service_repos &= repo_filter
  monolith_repos &= repo_filter
end
service_pattern = Regexp.new(mltc_cfg['service_pipeline_pattern'], Regexp::IGNORECASE)
monolith_pattern = Regexp.new(mltc_cfg['monolith_pipeline_pattern'])
me = my_display_name

def bb(path, params = nil)
  http_get("https://api.bitbucket.org/2.0/repositories/#{BB_WORKSPACE}/#{path}", params)
end

def iso_utc(raw)
  Time.parse(raw).utc.strftime('%Y-%m-%dT%H:%M:%SZ')
rescue StandardError
  raw.to_s
end

# Production pipelines completed inside the range (newest-first walk, stops
# once a page reaches pipelines older than start_date).
def production_pipelines(repo, pattern, start_date, end_date)
  url = "https://api.bitbucket.org/2.0/repositories/#{BB_WORKSPACE}/#{repo}/pipelines/"
  params = { pagelen: 50, sort: '-created_on' }
  found = []
  loop do
    page = http_get(url, params)
    values = page['values'] || []
    break if values.empty?
    values.each do |p|
      next unless p['completed_on']
      d = Date.parse(p['completed_on'])
      next if d > end_date
      break if d < start_date
      found << p if p.dig('target', 'selector', 'pattern').to_s =~ pattern
    end
    break if values.any? { |p| p['completed_on'] && Date.parse(p['completed_on']) < start_date }
    nxt = page['next']
    break if nxt.nil? || nxt.to_s.empty?
    url = nxt.include?('sort=') ? nxt : "#{nxt}&sort=-created_on"
    params = nil
  end
  found
end

def lead_time_row(rows, repo, pipeline, pr_html, author, first_commit_raw)
  deployment_time = iso_utc(pipeline['completed_on'])
  first_commit = first_commit_raw.to_s.empty? ? '' : iso_utc(first_commit_raw)
  hours = ''
  if deployment_time != '' && first_commit != ''
    hours = business_hours(Time.parse(first_commit), Time.parse(deployment_time))
  end
  rows << { repo: repo,
            pipeline_link: "https://bitbucket.org/#{BB_WORKSPACE}/#{repo}/pipelines/results/#{pipeline['build_number']}",
            deployment_time: deployment_time,
            commit_id: pipeline.dig('target', 'commit', 'hash'),
            pr_link: pr_html, author: author,
            first_commit_date: first_commit, hours: hours }
end

# --- Services: deploy pipeline commit -> PRs -> first commit of each PR ---
def collect_service_rows(repo, pattern, start_date, end_date, rows)
  pipelines = production_pipelines(repo, pattern, start_date, end_date)
  progress "#{repo}: #{pipelines.size} production deploy(s) in range"
  pipelines.each do |pipeline|
    commit_id = pipeline.dig('target', 'commit', 'hash') or next
    prs = bb("#{repo}/commit/#{commit_id}/pullrequests")['values'] || []
    prs.each do |pr|
      details = bb("#{repo}/pullrequests/#{pr['id']}")
      author = details.dig('author', 'display_name') || ''
      commits = bb("#{repo}/pullrequests/#{pr['id']}/commits", { pagelen: 50 })['values']
      first_commit_raw = commits&.any? ? commits.last['date'] : ''
      lead_time_row(rows, repo, pipeline,
                    "https://bitbucket.org/#{BB_WORKSPACE}/#{repo}/pull-requests/#{pr['id']}",
                    author, first_commit_raw)
    end
  end
end

# --- Monolith: deploy commit -> release-tag PR (v1.2.3) -> merged TD/TBB commits
#     -> author's original PR -> author's first commit ---
def collect_monolith_rows(repo, pattern, start_date, end_date, rows)
  pipelines = production_pipelines(repo, pattern, start_date, end_date)
  progress "#{repo}: #{pipelines.size} production deploy(s) in range"
  pipelines.each do |pipeline|
    commit_id = pipeline.dig('target', 'commit', 'hash') or next
    tag_prs = (bb("#{repo}/commit/#{commit_id}/pullrequests")['values'] || [])
              .select { |pr| pr['title'] =~ /^v[0-9]+\.[0-9]+\.[0-9]+/ }
    tag_prs.each do |tag_pr|
      url = "https://api.bitbucket.org/2.0/repositories/#{BB_WORKSPACE}/#{repo}/pullrequests/#{tag_pr['id']}/commits"
      params = { pagelen: 50 }
      loop do
        page = http_get(url, params)
        (page['values'] || []).each do |commit|
          next unless commit['message'] =~ /Merged in/
          next unless commit['message'] =~ /TD-[0-9]+|TBB-[0-9]+/
          author = commit.dig('author', 'user', 'display_name') or next
          candidate_prs = bb("#{repo}/commit/#{commit['hash']}/pullrequests")['values'] || []
          candidate_prs.each do |pr_item|
            details = bb("#{repo}/pullrequests/#{pr_item['id']}")
            break unless details.dig('author', 'display_name') == author
            commits = bb("#{repo}/pullrequests/#{pr_item['id']}/commits", { pagelen: 50 })['values'] || []
            first = commits.reverse.find { |c| c.dig('author', 'user', 'display_name') == author }
            lead_time_row(rows, repo, pipeline,
                          "https://bitbucket.org/#{BB_WORKSPACE}/#{repo}/pull-requests/#{pr_item['id']}",
                          author, first ? first['date'] : '')
            break
          end
        end
        url = page['next']
        break if url.nil? || url.to_s.empty?
        params = nil
      end
    end
  end
end

rows = []
service_repos.each { |r| collect_service_rows(r, service_pattern, start_date, end_date, rows) }
monolith_repos.each { |r| collect_monolith_rows(r, monolith_pattern, start_date, end_date, rows) }

# A PR shipped in several deploys counts once, at its earliest deploy (min lead time).
deduped = rows.group_by { |r| [r[:pr_link], r[:author]] }.map do |_, group|
  numeric = group.select { |g| g[:hours].is_a?(Numeric) }
  numeric.min_by { |g| g[:hours] } || group.first
end

puts "## MLTC — #{start_date} to #{end_date}"
puts
puts '### Median lead time per author'
puts
puts '| Author | PRs deployed | Median lead time (business hours) | ≈ days |'
puts '|---|---|---|---|'
deduped.group_by { |r| r[:author] }.sort_by { |name, _| name.to_s.downcase }.each do |name, list|
  hours = list.map { |r| r[:hours] }.select { |h| h.is_a?(Numeric) }
  med = median(hours)
  marker = name == me ? ' ⭐' : ''
  puts "| #{name}#{marker} | #{list.size} | #{med || 'n/a'} | #{med ? (med / 24.0).round(2) : 'n/a'} |"
end
puts

csv_rows = flag?(ARGV, 'all') ? deduped : deduped.select { |r| r[:author] == me }
puts "### CSV (paste into the MLTC Google Sheet#{flag?(ARGV, 'all') ? '' : " — your rows only, use --all for everyone"})"
puts
puts '```csv'
puts 'repo,pipeline_link,deployment_time,commit_id,pr_link,pr_author,first_commit_date,lead_time_change_hours'
csv_rows.sort_by { |r| r[:deployment_time].to_s }.each do |r|
  puts [r[:repo], r[:pipeline_link], r[:deployment_time], r[:commit_id],
        r[:pr_link], r[:author], r[:first_commit_date], r[:hours]].join(',')
end
puts '```'
