#!/usr/bin/env ruby
# Evidence links for the qualitative-ish KRs: PIC epics, tech debt, production
# bugs (TBB), and Confluence docs you authored/edited in the period.
# Usage: ruby evidence.rb 2026-06
#        ruby evidence.rb 2026-06-01 2026-06-30
require_relative 'common'

start_date, end_date = parse_range(ARGV)
me = my_display_name

def fill(template, start_date, end_date)
  template.gsub('{start}', start_date.to_s).gsub('{end}', end_date.to_s)
end

def print_jira_section(title, jql, note = nil)
  progress "Jira: #{title}"
  issues = jira_search(jql, %w[summary status issuetype], true)
  puts "### #{title}"
  puts
  puts "_JQL: `#{jql}`_"
  puts
  if issues.nil?
    puts '_⚠️ Query failed — adjust this JQL in config.yml for your team\'s conventions._'
  elsif issues.empty?
    puts '_No matching issues._'
  else
    issues.each do |i|
      puts "- [#{i['key']}](#{JIRA_SITE}/browse/#{i['key']}) — #{i.dig('fields', 'summary')} (#{i.dig('fields', 'status', 'name')})"
    end
  end
  puts note if note
  puts
end

puts "## OKR evidence — #{start_date} to #{end_date} (#{me})"
puts

jql_cfg = CONFIG.dig('jira', 'jql')
print_jira_section('PIC initiatives (Epics done)', fill(jql_cfg['pic_epics'], start_date, end_date))
print_jira_section('Tech debt items', fill(jql_cfg['tech_debt'], start_date, end_date))
print_jira_section('Production bugs (TBB)', fill(jql_cfg['production_bugs'], start_date, end_date))

progress 'Confluence: pages you contributed to'
puts '### Technical documentation (Confluence pages you created/edited)'
puts
cql = fill(CONFIG.dig('confluence', 'cql'), start_date, end_date)
puts "_CQL: `#{cql}`_"
puts
results = []
url = "#{CONFLUENCE_BASE}/rest/api/search"
params = { cql: cql, limit: 50 }
loop do
  page = http_get(url, params, true)
  break if page.nil?
  results.concat(page['results'] || [])
  nxt = page.dig('_links', 'next')
  break if nxt.nil? || nxt.to_s.empty?
  url = "#{CONFLUENCE_BASE}#{nxt}"
  params = nil
end
if results.empty?
  puts '_No pages found (or query failed — adjust the CQL in config.yml)._'
else
  results.each do |r|
    title = r.dig('content', 'title') || r['title']
    webui = r.dig('content', '_links', 'webui')
    link = webui ? "#{CONFLUENCE_SITE}#{webui}" : ''
    puts "- [#{title}](#{link}) — last modified #{r['friendlyLastModified'] || ''}"
  end
end
