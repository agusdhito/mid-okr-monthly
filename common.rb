# Shared helpers for okr-monthly collectors.
# Auth comes from ATLASSIAN_EMAIL / ATLASSIAN_API_TOKEN env vars — never hardcode tokens.
require 'net/http'
require 'json'
require 'uri'
require 'date'
require 'time'
require 'yaml'

# Config lives next to the scripts (~/scripts/okr-config.yml). The skill dir is
# kept as a fallback so an older layout still resolves; override with OKR_CONFIG.
CONFIG_CANDIDATES = [
  ENV['OKR_CONFIG'],
  File.join(__dir__, 'okr-config.yml'),
  File.join(__dir__, 'config.yml'),
  File.expand_path('../config.yml', __dir__),
  File.expand_path('~/.claude/skills/okr-monthly/config.yml')
].compact.freeze
CONFIG_PATH = CONFIG_CANDIDATES.find { |c| File.exist?(c) }
unless CONFIG_PATH
  abort "Cannot find okr-config.yml. Looked in:\n  #{CONFIG_CANDIDATES.join("\n  ")}\n" \
        'Set OKR_CONFIG=/path/to/okr-config.yml to point at it explicitly.'
end
CONFIG = YAML.load_file(CONFIG_PATH)

EMAIL = ENV['ATLASSIAN_EMAIL'].to_s
if EMAIL.empty?
  abort "Missing ATLASSIAN_EMAIL.\n  export ATLASSIAN_EMAIL=\"you@mekari.com\""
end

# Tokens are per-service: Atlassian issues Jira, Confluence and Bitbucket tokens
# separately now, so a single unscoped token is no longer the norm. Each service
# falls back to ATLASSIAN_API_TOKEN when a dedicated one isn't set.
FALLBACK_TOKEN = ENV['ATLASSIAN_API_TOKEN'].to_s
SERVICE_TOKENS = {
  jira: ['ATLASSIAN_JIRA_TOKEN', ENV['ATLASSIAN_JIRA_TOKEN'].to_s],
  confluence: ['ATLASSIAN_CONFLUENCE_TOKEN', ENV['ATLASSIAN_CONFLUENCE_TOKEN'].to_s],
  bitbucket: ['BITBUCKET_API_TOKEN', ENV['BITBUCKET_API_TOKEN'].to_s]
}.freeze

# Jira and Confluence share the same host, so the /wiki path prefix is what
# separates them.
def service_for(uri)
  return :bitbucket if uri.host.to_s.include?('bitbucket.org')
  path = uri.path.to_s
  return :confluence if path.start_with?('/wiki') || path.start_with?("/ex/confluence")
  :jira
end

def token_for(uri)
  svc = service_for(uri)
  var, token = SERVICE_TOKENS[svc]
  token = FALLBACK_TOKEN if token.empty?
  if token.empty?
    abort "Missing #{svc} credentials for #{uri.host}.\n" \
          "Create a token at https://id.atlassian.com/manage-profile/security/api-tokens then:\n" \
          "  export #{var}=\"...\"   (or export ATLASSIAN_API_TOKEN for all three)"
  end
  token
end

JIRA_SITE = CONFIG.dig('jira', 'site').to_s.chomp('/')
CLOUD_ID = CONFIG.dig('jira', 'cloud_id').to_s
# API bases: the gateway when a cloud id is configured (required for scoped
# tokens), the site otherwise. *_SITE constants stay for building links people click.
JIRA_BASE = CLOUD_ID.empty? ? JIRA_SITE : "https://api.atlassian.com/ex/jira/#{CLOUD_ID}"
CONFLUENCE_SITE = "#{JIRA_SITE}/wiki"
CONFLUENCE_BASE = CLOUD_ID.empty? ? CONFLUENCE_SITE : "https://api.atlassian.com/ex/confluence/#{CLOUD_ID}"
BB_WORKSPACE = CONFIG.dig('bitbucket', 'workspace')

# soft = true returns nil on a 4xx instead of aborting (for optional queries like
# configurable JQL that may not match the Jira instance). `soft` is positional on
# purpose — a keyword arg would swallow trailing params hashes in Ruby 3.
def http_get(url, params = nil, soft = false)
  uri = URI(url)
  uri.query = URI.encode_www_form(params) if params && !params.empty?
  attempts = 0
  loop do
    attempts += 1
    req = Net::HTTP::Get.new(uri)
    req.basic_auth(EMAIL, token_for(uri))
    req['Accept'] = 'application/json'
    res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, read_timeout: 60) { |h| h.request(req) }
    code = res.code.to_i
    if code == 429 || code >= 500
      if attempts >= 4
        return nil if soft
        abort "Request kept failing (HTTP #{code}) for #{uri}"
      end
      sleep(2 * attempts)
      next
    end
    unless res.is_a?(Net::HTTPSuccess)
      return nil if soft
      hint = if [401, 403].include?(code)
               var = SERVICE_TOKENS[service_for(uri)][0]
               "\nYour #{var} can't access #{uri.host} — create a fresh token at " \
               'https://id.atlassian.com/manage-profile/security/api-tokens and re-export it.'
             else
               ''
             end
      abort "HTTP #{code} for #{uri}\n#{res.body.to_s[0, 300]}#{hint}"
    end
    return JSON.parse(res.body)
  end
end

# Follows Bitbucket cursor pagination, yielding each item in `values`.
def bitbucket_each(url, params = nil)
  loop do
    page = http_get(url, params)
    (page['values'] || []).each { |v| yield v }
    nxt = page['next']
    break if nxt.nil? || nxt.to_s.empty?
    url = nxt
    params = nil
  end
end

# Paginated Jira search (new /search/jql endpoint). Returns array of issues.
def jira_search(jql, fields, soft = false)
  issues = []
  token = nil
  loop do
    params = { jql: jql, fields: fields.join(','), maxResults: 100 }
    params[:nextPageToken] = token if token
    page = http_get("#{JIRA_BASE}/rest/api/3/search/jql", params, soft)
    return nil if page.nil?
    issues.concat(page['issues'] || [])
    token = page['nextPageToken']
    break if token.nil? || token.to_s.empty?
  end
  issues
end

def jira_myself
  @jira_myself ||= http_get("#{JIRA_BASE}/rest/api/3/myself")
end

# Jira and Bitbucket display names are the same Atlassian account; prefer Jira
# (it's what issue assignees are matched against) and fall back to Bitbucket
# when the token is Bitbucket-scoped.
def my_display_name
  @display_name ||= begin
    jira = http_get("#{JIRA_BASE}/rest/api/3/myself", nil, true)
    jira ? jira['displayName'] : http_get('https://api.bitbucket.org/2.0/user')['display_name']
  end
end

# Args: "YYYY-MM" | "YYYY-MM-DD YYYY-MM-DD" | none (previous calendar month).
# Flags (--foo / --foo=bar) are ignored here; read them from ARGV yourself.
def parse_range(argv)
  dates = argv.reject { |a| a.start_with?('--') }
  if dates[0] =~ /\A\d{4}-\d{2}\z/
    first = Date.parse("#{dates[0]}-01")
    [first, Date.new(first.year, first.month, -1)]
  elsif dates[0] && dates[1]
    [Date.parse(dates[0]), Date.parse(dates[1])]
  else
    last_prev = Date.new(Date.today.year, Date.today.month, 1) - 1
    [Date.new(last_prev.year, last_prev.month, 1), last_prev]
  end
end

def flag_value(argv, name)
  arg = argv.find { |a| a.start_with?("--#{name}=") }
  arg && arg.split('=', 2)[1]
end

def flag?(argv, name)
  argv.include?("--#{name}")
end

# Business hours between two times: 24h/day, weekends excluded
# (same definition as the original MLTC scripts).
def business_hours(start_time, end_time)
  total = 0.0
  current = start_time
  while current < end_time
    unless current.saturday? || current.sunday?
      if current.to_date == end_time.to_date
        total += (end_time - current) / 3600.0
      else
        end_of_day = Time.new(current.year, current.month, current.day, 23, 59, 59, current.utc_offset)
        total += (end_of_day - current + 1) / 3600.0
      end
    end
    current = Time.new(current.year, current.month, current.day, 0, 0, 0, current.utc_offset) + 86_400
  end
  total.round(2)
end

def median(numbers)
  return nil if numbers.empty?
  sorted = numbers.sort
  mid = sorted.size / 2
  sorted.size.odd? ? sorted[mid] : ((sorted[mid - 1] + sorted[mid]) / 2.0).round(2)
end

def progress(msg)
  warn "[#{Time.now.strftime('%H:%M:%S')}] #{msg}"
end

# --- Additions for the OKR row 10/11/12 collectors ---------------------------

# Strict period parsing: these collectors bucket by week, so an explicit
# start_date AND end_date are required (no month shorthand, no defaulting).
def require_range(argv, script)
  dates = argv.reject { |a| a.start_with?('--') }
  unless dates.size == 2 && dates.all? { |d| d =~ /\A\d{4}-\d{2}-\d{2}\z/ }
    abort "Usage: ruby #{script} <start_date> <end_date> [flags]\n" \
          "  both dates required, format YYYY-MM-DD\n" \
          "  e.g. ruby #{script} 2026-07-01 2026-09-30"
  end
  start_date = Date.parse(dates[0])
  end_date = Date.parse(dates[1])
  abort "start_date #{start_date} is after end_date #{end_date}" if start_date > end_date
  [start_date, end_date]
end

# Level config (weights + targets differ per L1/L2/L3 in the OKR template).
def level_config(argv)
  level = (flag_value(argv, 'level') || 'L1').upcase
  cfg = CONFIG.dig('levels', level)
  unless cfg
    have = (CONFIG['levels'] || {}).keys.join(', ')
    abort "No targets for level #{level} in config.yml (have: #{have}).\n" \
          "Add a levels.#{level} block — do not reuse another level's numbers, the templates differ."
  end
  [level, cfg]
end

# ISO week key (Monday-start), e.g. "2026-W36". Used as the efficiency bucket.
def week_key(date)
  d = date.respond_to?(:to_date) ? date.to_date : date
  format('%d-W%02d', d.cwyear, d.cweek)
end

# Every ISO week touched by the period, in order.
def weeks_in(start_date, end_date)
  keys = []
  d = start_date
  while d <= end_date
    k = week_key(d)
    keys << k unless keys.include?(k)
    d += 1
  end
  keys
end

# Working days (Mon-Fri) of a given ISO week that fall inside the period —
# the efficiency divider is 5, but a partial first/last week would otherwise
# be scored against a full week.
def working_days_in_week(key, start_date, end_date)
  d = start_date
  count = 0
  while d <= end_date
    count += 1 if week_key(d) == key && !d.saturday? && !d.sunday?
    d += 1
  end
  count
end

# Paginated Confluence CQL search. Returns array of results (may be empty).
def confluence_search(cql, limit = 100)
  results = []
  start = 0
  loop do
    page = http_get("#{CONFLUENCE_BASE}/rest/api/search",
                    { cql: cql, limit: limit, start: start }, true)
    # nil on the first page means the call failed (bad CQL or, more often, a
    # Confluence token without content/search scope) — that is NOT "no docs".
    return (results.empty? ? nil : results) if page.nil?
    batch = page['results'] || []
    results.concat(batch)
    break if batch.size < limit
    start += limit
  end
  results
end

def render_template(template, vars)
  vars.reduce(template.to_s) { |acc, (k, v)| acc.gsub("{#{k}}", v.to_s) }
end
