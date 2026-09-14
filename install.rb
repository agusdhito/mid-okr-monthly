#!/usr/bin/env ruby
# install.rb — interactive setup + credential doctor for the okr-monthly collectors.
#
# SELF-CONTAINED ON PURPOSE. It does not require_relative 'common' — common.rb
# aborts when okr-config.yml is missing or ATLASSIAN_EMAIL is unset, which is
# exactly the state this script exists to fix. The token-resolution rules below
# are deliberately a copy of common.rb's, so the doctor reports on the same
# credentials the collectors will actually use.
#
# Usage:
#   ruby install.rb            # interview -> write okr-config.yml -> doctor
#   ruby install.rb --doctor   # probes only: no prompts, no writes
#   ruby install.rb --yes      # take every detected/existing default (repair re-run)
#
# It never reads, prints, logs or stores a token VALUE. Tokens live in env vars;
# this script only reports which vars are set and what each one can reach.
require 'net/http'
require 'json'
require 'uri'
require 'yaml'
require 'date'

DOCTOR_ONLY = ARGV.include?('--doctor')
ASSUME_YES  = ARGV.include?('--yes')
HERE        = File.expand_path(__dir__)
CONFIG_PATH = ENV['OKR_CONFIG'] || File.join(HERE, 'okr-config.yml')

# --- tiny terminal helpers ---------------------------------------------------
TTY = $stdout.tty?
def c(code, s) TTY ? "\e[#{code}m#{s}\e[0m" : s end
def bold(s)  c('1', s)  end
def dim(s)   c('2', s)  end
def green(s) c('32', s) end
def red(s)   c('31', s) end
def yellow(s) c('33', s) end
def cyan(s)  c('36', s) end

def heading(s)
  puts
  puts bold("== #{s} ")
end

def note(s) puts "   #{dim(s)}" end
def ok(s)   puts "   #{green('OK')}    #{s}" end
def bad(s)  puts "   #{red('FAIL')}  #{s}" end
def warn_(s) puts "   #{yellow('WARN')}  #{s}" end

# Prompt with a default. Returns a String (possibly empty if no default given).
def ask(label, default = nil)
  if ASSUME_YES && !default.nil? && default.to_s != ''
    puts "   #{label}: #{cyan(default.to_s)} #{dim('(--yes)')}"
    return default.to_s
  end
  suffix = (default.nil? || default.to_s.empty?) ? '' : " [#{cyan(default.to_s)}]"
  loop do
    print "   #{label}#{suffix}: "
    line = $stdin.gets
    abort "\nAborted." if line.nil?
    line = line.strip
    return line unless line.empty?
    return default.to_s unless default.nil? || default.to_s.empty?
    puts "   #{red('required')}"
  end
end

def ask_yes(label, default_yes = true)
  return default_yes if ASSUME_YES
  d = default_yes ? 'Y/n' : 'y/N'
  print "   #{label} [#{d}]: "
  line = $stdin.gets
  abort "\nAborted." if line.nil?
  a = line.strip.downcase
  return default_yes if a.empty?
  a.start_with?('y')
end

# Comma- or whitespace-separated list, editable as one line.
def ask_list(label, default_list)
  d = Array(default_list).join(',')
  raw = ask("#{label} #{dim('(comma-separated)')}", d)
  raw.split(/[,\s]+/).map { |x| x.strip }.reject { |x| x.empty? }.uniq
end

# Numbered pick from [[value, display], ...]. Also accepts a raw typed value.
def ask_pick(label, choices, default_value = nil)
  choices.each_with_index { |(_v, disp), i| puts "     #{(i + 1).to_s.rjust(2)}) #{disp}" }
  if ASSUME_YES && default_value
    puts "   #{label}: #{cyan(default_value.to_s)} #{dim('(--yes)')}"
    return default_value
  end
  # A typed value may itself be numeric (filter ids are), so a number only means
  # "row N" while it is actually in range; anything else is taken literally.
  loop do
    got = ask("#{label} #{dim("(1-#{choices.size} to pick, or paste a value)")}", default_value)
    if got =~ /\A\d+\z/ && got.to_i >= 1 && got.to_i <= choices.size
      return choices[got.to_i - 1][0]
    elsif !got.to_s.strip.empty?
      return got
    end
    puts "   #{red("pick 1-#{choices.size}, or paste a value")}"
  end
end

# --- credentials (mirrors common.rb) -----------------------------------------
EMAIL = ENV['ATLASSIAN_EMAIL'].to_s
FALLBACK = ENV['ATLASSIAN_API_TOKEN'].to_s
SERVICE_VARS = {
  jira: 'ATLASSIAN_JIRA_TOKEN',
  confluence: 'ATLASSIAN_CONFLUENCE_TOKEN',
  bitbucket: 'BITBUCKET_API_TOKEN'
}.freeze

def token_for_service(svc)
  t = ENV[SERVICE_VARS[svc]].to_s
  t = FALLBACK if t.empty?
  t
end

def have_token?(svc) !token_for_service(svc).empty? end

def missing_credentials
  m = []
  m << 'ATLASSIAN_EMAIL' if EMAIL.empty?
  SERVICE_VARS.each { |svc, var| m << var unless have_token?(svc) }
  m
end

# Printed, never collected. install.rb does not read or store token values.
def print_export_help(missing)
  puts
  puts "   #{bold('Export these, then re-run.')} Add them to ~/.zshrc to persist:"
  puts
  puts '     export ATLASSIAN_EMAIL="you@company.com"' if missing.include?('ATLASSIAN_EMAIL')
  puts '     export ATLASSIAN_JIRA_TOKEN="..."'        if missing.include?('ATLASSIAN_JIRA_TOKEN')
  puts '     export ATLASSIAN_CONFLUENCE_TOKEN="..."'  if missing.include?('ATLASSIAN_CONFLUENCE_TOKEN')
  puts '     export BITBUCKET_API_TOKEN="..."'         if missing.include?('BITBUCKET_API_TOKEN')
  puts
  puts "   #{dim('Atlassian tokens: https://id.atlassian.com/manage-profile/security/api-tokens')}"
  puts "   #{dim('  Jira needs      read:jira-work, read:jira-user')}"
  puts "   #{dim('  Confluence needs read:page:confluence, search:confluence')}"
  puts "   #{dim('Bitbucket token:  https://bitbucket.org/account/settings/api-tokens/')}"
  puts "   #{dim('  needs Pull requests: Read (and Repositories: Read)')}"
  puts "   #{dim('One ATLASSIAN_API_TOKEN can stand in for all three Atlassian vars.')}"
end

# Returns [http_code, parsed_body_or_nil]. Never raises on HTTP status.
def req(svc, url, params = nil)
  uri = URI(url)
  uri.query = URI.encode_www_form(params) if params && !params.empty?
  r = Net::HTTP::Get.new(uri)
  tok = token_for_service(svc)
  r.basic_auth(EMAIL, tok) unless EMAIL.empty? || tok.empty?
  r['Accept'] = 'application/json'
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, open_timeout: 15, read_timeout: 45) do |h|
    h.request(r)
  end
  body = begin
    JSON.parse(res.body)
  rescue StandardError
    nil
  end
  [res.code.to_i, body]
rescue StandardError => e
  [0, { '_error' => e.message }]
end

# --- existing config (all optional) ------------------------------------------
OLD = File.exist?(CONFIG_PATH) ? (YAML.load_file(CONFIG_PATH) || {}) : {}
def old_dig(*path) OLD.dig(*path) end

def flatten_cfg(obj, prefix = '', out = {})
  case obj
  when Hash  then obj.each { |k, v| flatten_cfg(v, prefix.empty? ? k.to_s : "#{prefix}.#{k}", out) }
  when Array then out[prefix] = obj.inspect
  else out[prefix] = obj.inspect
  end
  out
end

# --- known-good level targets (from the OKR templates; not guessable) --------
# L2 is deliberately absent: its template has not been read, and inventing its
# numbers would silently produce a wrong KR. Add a block only from the template.
LEVEL_DEFAULTS = {
  'L1' => { 'review_time_target_days' => 2, 'review_stop_events' => %w[approve reject],
            'efficiency_review_events' => %w[approve reject comment],
            'efficiency_target' => 2.25, 'copilot_target_pct' => 50, 'mltc_target_days' => 5 },
  'L3' => { 'review_time_target_days' => 1.5, 'review_stop_events' => %w[approve reject comment],
            'efficiency_review_events' => %w[approve reject comment],
            'efficiency_target' => 3.5, 'copilot_target_pct' => 50, 'mltc_target_days' => 4 }
}.freeze

# =============================================================================
#  DOCTOR
# =============================================================================
# Each probe names the stream it gates, so a failure says what breaks, not just
# which URL 401'd. Confluence is the cautionary case: /rest/api/space answers 200
# on a token that cannot read /rest/api/search, so probing "can I reach
# Confluence" passes while the docs stream silently reports zero.
def run_doctor(cfg)
  heading 'Doctor — credentials and capabilities'

  if EMAIL.empty?
    bad 'ATLASSIAN_EMAIL is not set — every Atlassian call will fail.'
  else
    ok "ATLASSIAN_EMAIL = #{EMAIL}"
  end
  SERVICE_VARS.each do |svc, var|
    if !ENV[var].to_s.empty?
      ok "#{var} is set"
    elsif !FALLBACK.empty?
      warn_ "#{var} unset — falling back to ATLASSIAN_API_TOKEN for #{svc}"
    else
      bad "#{var} unset and no ATLASSIAN_API_TOKEN fallback — #{svc} unavailable"
    end
  end

  site     = cfg.dig('jira', 'site').to_s.chomp('/')
  cloud    = cfg.dig('jira', 'cloud_id').to_s
  jira_b   = cloud.empty? ? site : "https://api.atlassian.com/ex/jira/#{cloud}"
  conf_b   = cloud.empty? ? "#{site}/wiki" : "https://api.atlassian.com/ex/confluence/#{cloud}"
  ws       = cfg.dig('bitbucket', 'workspace').to_s
  repo     = Array(cfg.dig('bitbucket', 'copilot_repos')).first.to_s
  filter   = cfg.dig('jira', 'oncall', 'filter_id')
  board    = cfg.dig('jira', 'oncall', 'board_id')

  results = []
  add = lambda { |stream, pass, detail| results << [stream, pass, detail] }

  puts
  note 'probing…'

  # Authenticate Jira FIRST. An unauthenticated Jira search answers
  # HTTP 200 {"issues":[],"isLast":true} — success with zero rows, which is
  # indistinguishable from "you genuinely have no oncall tickets". So a 200 only
  # means something once /rest/api/3/myself (which does 401 anonymously) passes.
  code_me, me_j = req(:jira, "#{jira_b}/rest/api/3/myself")
  jira_authed = code_me == 200 && me_j && !me_j['displayName'].to_s.empty?
  _, me_b = req(:bitbucket, 'https://api.bitbucket.org/2.0/user')

  # 1. Jira platform search -> oncall stream
  if !jira_authed
    add.call('Oncall done', false,
             "Jira is not authenticated (HTTP #{code_me} on /rest/api/3/myself) — an " \
             'anonymous Jira search still returns 200 with zero rows, so this cannot be verified')
  elsif filter.to_s.empty?
    add.call('Oncall done', false, 'jira.oncall.filter_id is not set in the config')
  else
    code, = req(:jira, "#{jira_b}/rest/api/3/search/jql",
                jql: "filter = #{filter}", fields: 'summary', maxResults: 1)
    add.call('Oncall done', code == 200,
             code == 200 ? "filter #{filter} readable via /rest/api/3/search/jql"
                         : "HTTP #{code} on /rest/api/3/search/jql — token needs read:jira-work")
  end

  # 2. Confluence CQL search -> docs stream. Probe search, NOT /space.
  code_sp, = req(:confluence, "#{conf_b}/rest/api/space", limit: 1)
  code_se, = req(:confluence, "#{conf_b}/rest/api/search", cql: 'type = page', limit: 1)
  detail = if code_se == 200
             '/rest/api/search readable'
           elsif code_sp == 200
             "HTTP #{code_se} on /rest/api/search while /rest/api/space returns 200 — " \
             'the token can list spaces but not read pages. Needs read:page:confluence + search:confluence'
           else
             "HTTP #{code_se} on /rest/api/search — needs read:page:confluence + search:confluence"
           end
  add.call('Docs updated', code_se == 200, detail)

  # 3 + 4. Bitbucket PR list and PR activity -> the two PR streams
  if ws.empty? || repo.empty?
    add.call('PR created', false, 'bitbucket.workspace or copilot_repos not configured')
    add.call('PR reviewed', false, 'bitbucket.workspace or copilot_repos not configured')
  else
    base = "https://api.bitbucket.org/2.0/repositories/#{ws}/#{repo}"
    code, body = req(:bitbucket, "#{base}/pullrequests",
                     pagelen: 1, fields: 'values.id', q: 'state="MERGED"')
    add.call('PR created', code == 200,
             code == 200 ? "#{ws}/#{repo} pull requests readable"
                         : "HTTP #{code} on #{repo}/pullrequests — token needs Pull requests: Read")
    pr_id = code == 200 ? (body['values'] || []).map { |v| v['id'] }.first : nil
    if pr_id
      acode, = req(:bitbucket, "#{base}/pullrequests/#{pr_id}/activity", pagelen: 1)
      add.call('PR reviewed', acode == 200,
               acode == 200 ? "PR activity feed readable (approvals/comments)"
                            : "HTTP #{acode} on the activity feed — approvals cannot be counted")
    else
      add.call('PR reviewed', false, 'could not fetch a PR to test the activity feed against')
    end
  end

  # 5. Jira filter read — used by install itself to resolve the oncall board.
  # Same caveat as above: only meaningful once Jira is actually authenticated.
  if !jira_authed
    add.call('(setup) filter lookup', false, 'Jira is not authenticated')
  else
    code, = req(:jira, "#{jira_b}/rest/api/3/filter/search", filterName: 'a', maxResults: 1)
    add.call('(setup) filter lookup', code == 200,
             code == 200 ? '/rest/api/3/filter/search readable'
                         : "HTTP #{code} — install cannot list saved filters for you to pick from")
  end

  puts
  results.each do |stream, pass, detail|
    pass ? ok("#{stream.ljust(20)} #{dim(detail)}") : bad("#{stream.ljust(20)} #{detail}")
  end

  # Optional: the agile API. No collector needs it since sprint.rb was removed.
  puts
  if board.to_s.empty?
    note 'agile API not probed (no oncall board_id configured)'
  else
    acode, = req(:jira, "#{jira_b}/rest/agile/1.0/board/#{board}/configuration")
    if acode == 200
      ok "(optional) agile API readable — board #{board} -> filter can be auto-resolved"
    else
      note "(optional) agile API HTTP #{acode} — not needed by any collector; " \
           'only lets install auto-resolve the board\'s filter instead of asking you'
    end
  end

  # Identity match. efficiency.rb compares Jira assignee displayName and Bitbucket
  # author display_name against ONE name, so a mismatch silently drops artifacts.
  puts
  jn = me_j && me_j['displayName']
  bn = me_b && me_b['display_name']
  if jn && bn && jn == bn
    ok "identity matches on both sides: #{bold(jn)}"
  elsif jn && bn
    add.call('identity', false,
             "Jira says #{jn.inspect} but Bitbucket says #{bn.inspect} — the collectors match " \
             'one name against both, so artifacts on the mismatched side are silently dropped')
    bad results.last[2]
  elsif jn || bn
    warn_ "could not read identity from #{jn ? 'Bitbucket' : 'Jira'} — cannot verify the names match"
  else
    add.call('identity', false, 'neither Jira nor Bitbucket returned an identity — ' \
                                'the collectors cannot attribute any artifact to you')
    bad results.last[2]
  end

  failed = results.select { |_s, pass, _d| !pass }
  puts
  if failed.empty?
    puts "   #{green('All 4 artifact streams are readable.')}"
  else
    puts "   #{red("#{failed.size} check(s) failed.")} Affected columns report 0 and " \
         'efficiency.rb will banner them as unknown, not zero.'
    miss = missing_credentials
    print_export_help(miss) unless miss.empty?
  end
  failed.empty?
end

# =============================================================================
#  INTERVIEW
# =============================================================================
def run_interview
  cfg = {}

  heading 'Step 1 — Atlassian site'
  site_in = ask('Jira/Confluence site URL', old_dig('jira', 'site') || 'https://your-org.atlassian.net')
  site = site_in.strip.sub(%r{/+\z}, '')
  site = "https://#{site}" unless site.start_with?('http')
  site = site.sub(%r{/wiki.*\z}, '').sub(%r{/jira.*\z}, '')

  # cloud_id is auto-discoverable and unauthenticated. Scoped (~192-char) tokens
  # are rejected by the site host and MUST route via api.atlassian.com/ex/*, which
  # is keyed by cloud id — so this value is load-bearing, not cosmetic.
  cloud = nil
  begin
    code, body = req(:jira, "#{site}/_edge/tenant_info")
    cloud = body && body['cloudId'] if code == 200
  rescue StandardError
    cloud = nil
  end
  if cloud
    ok "cloud_id auto-detected: #{cloud}"
  else
    warn_ 'could not auto-detect cloud_id from /_edge/tenant_info'
    cloud = ask('cloud_id (blank = talk to the site host directly)', old_dig('jira', 'cloud_id') || '')
    cloud = nil if cloud.to_s.strip.empty?
  end
  jira_b = cloud ? "https://api.atlassian.com/ex/jira/#{cloud}" : site

  heading 'Step 2 — Identity'
  _, me_j = req(:jira, "#{jira_b}/rest/api/3/myself")
  _, me_b = req(:bitbucket, 'https://api.bitbucket.org/2.0/user')
  jn = me_j && me_j['displayName']
  bn = me_b && me_b['display_name']
  note "Jira      : #{jn || red('unreadable')}"
  note "Bitbucket : #{bn || red('unreadable')}"
  if jn && bn && jn != bn
    warn_ 'These differ. The collectors match ONE display name against both APIs, so ' \
          'whichever side does not match will silently contribute nothing.'
    abort "\nFix the display names (or the tokens) first, then re-run." unless
      ask_yes('Continue anyway?', false)
  end

  heading 'Step 3 — OKR level'
  note 'Targets come from the OKR templates. L2 is absent on purpose — its template'
  note 'has not been read, and inventing its numbers would produce a wrong KR.'
  level = ask_pick('Your level',
                   LEVEL_DEFAULTS.keys.map { |k|
                     d = LEVEL_DEFAULTS[k]
                     [k, "#{k} — efficiency >= #{d['efficiency_target']}, " \
                         "review <= #{d['review_time_target_days']}d, " \
                         "MLTC <= #{d['mltc_target_days']}d"]
                   },
                   (OLD['levels'] || {}).keys.first || 'L1')
  unless LEVEL_DEFAULTS.key?(level)
    abort red("No template targets known for #{level}. Read that level's OKR template and " \
              'add a levels block by hand rather than reusing another level\'s numbers.')
  end

  heading 'Step 4 — Bitbucket'
  note 'GET /2.0/workspaces returns 404 on API-token auth, so this cannot be listed.'
  ws = ask('Workspace slug', old_dig('bitbucket', 'workspace') || '')
  repos = ask_list('Repos to scan', old_dig('bitbucket', 'copilot_repos') || [])
  if have_token?(:bitbucket) && !repos.empty?
    note 'validating repo slugs…'
    bad_repos = []
    repos.each do |r|
      code, = req(:bitbucket, "https://api.bitbucket.org/2.0/repositories/#{ws}/#{r}", fields: 'slug')
      bad_repos << "#{r} (HTTP #{code})" if code != 200
    end
    if bad_repos.empty?
      ok "all #{repos.size} repo(s) resolve"
    else
      bad "unreachable: #{bad_repos.join(', ')}"
      abort "\nFix the repo list and re-run." unless ask_yes('Keep them anyway?', false)
    end
  end

  heading 'Step 5 — MLTC deploy sources'
  note 'Services deploy per-repo; the monolith ships via tag pipelines, so they are split.'
  svc = ask_list('Service repos', old_dig('bitbucket', 'mltc', 'service_repos') || repos)
  mono = ask_list('Monolith repos', old_dig('bitbucket', 'mltc', 'monolith_repos') || [])
  svc_pat = ask('Service prod-pipeline pattern',
                old_dig('bitbucket', 'mltc', 'service_pipeline_pattern') || 'prod')
  mono_pat = ask('Monolith prod-pipeline pattern (regex)',
                 old_dig('bitbucket', 'mltc', 'monolith_pipeline_pattern') || '')

  heading 'Step 6 — Oncall board (efficiency stream 4)'
  note 'Paste the board URL, e.g. https://site/jira/software/c/projects/TD/boards/2556'
  board_in = ask('Board URL or id', old_dig('jira', 'oncall', 'board_id') || '')
  board_id = board_in.to_s[%r{boards?/(\d+)}, 1] || board_in.to_s[/\A\d+\z/]
  proj = board_in.to_s[%r{projects/([A-Z][A-Z0-9_]*)}, 1] ||
         old_dig('jira', 'oncall', 'project') || ''
  proj = ask('Oncall project key', proj)

  filter_id = resolve_filter(jira_b, board_id, proj)

  heading 'Step 7 — Evidence JQL'
  note 'Project keys differ per org; these feed evidence.rb only.'
  bug_proj = ask('Project key for production bugs',
                 (old_dig('jira', 'jql', 'production_bugs').to_s[/project = ([A-Z][A-Z0-9_]*)/, 1] || 'TBB'))

  {
    'level' => level, 'site' => site, 'cloud' => cloud, 'ws' => ws, 'repos' => repos,
    'svc' => svc, 'mono' => mono, 'svc_pat' => svc_pat, 'mono_pat' => mono_pat,
    'board_id' => board_id, 'filter_id' => filter_id, 'proj' => proj,
    'epics' => (old_dig('jira', 'oncall', 'epics') || []), 'bug_proj' => bug_proj
  }
end

# The board -> filter link is only exposed by the agile API. When that is out of
# scope we fall back to listing saved filters WITH their JQL for a human to
# confirm — never name-matching, because near-identical names are the norm
# ("Filter for TD Oncall" vs "Filter for TD Oncall & FT").
def resolve_filter(jira_b, board_id, proj)
  if board_id.to_s != ''
    code, body = req(:jira, "#{jira_b}/rest/agile/1.0/board/#{board_id}/configuration")
    if code == 200 && body && body.dig('filter', 'id')
      fid = body.dig('filter', 'id')
      ok "board #{board_id} -> filter #{fid} (resolved authoritatively via the agile API)"
      return fid.to_i
    end
    note "agile API unavailable (HTTP #{code}) — falling back to filter search"
  end
  term = ask('Search saved filters for', proj.to_s.empty? ? 'oncall' : "#{proj} oncall")
  code, body = req(:jira, "#{jira_b}/rest/api/3/filter/search",
                   filterName: term, expand: 'jql', maxResults: 25)
  vals = (code == 200 && body) ? (body['values'] || []) : []
  if vals.empty?
    warn_ "no filters matched #{term.inspect} (HTTP #{code})"
    return ask('Filter id for the oncall board', '').to_s
  end
  puts
  note 'Confirm by JQL, not by name — names are often near-identical:'
  choices = vals.map do |f|
    jql = f['jql'].to_s
    jql = jql[0, 150] + '…' if jql.length > 150
    [f['id'].to_i, "#{bold(f['id'].to_s)}  #{f['name']}\n         #{dim(jql)}"]
  end
  ask_pick('Which filter backs that board', choices, nil).to_i
end

# =============================================================================
#  CONFIG RENDERING
# =============================================================================
def yaml_list(items, indent)
  return " []" if Array(items).empty?
  "\n" + Array(items).map { |i| "#{' ' * indent}- #{i}" }.join("\n")
end

def render_config(a)
  lvl = LEVEL_DEFAULTS[a['level']]
  others = LEVEL_DEFAULTS.keys.reject { |k| k == a['level'] }
  # <<~ dedents to column 0, so each block is re-indented by 2 to actually nest
  # under `levels:`. Without this the level keys land as top-level siblings and
  # every collector aborts with "No targets for level L1".
  level_blocks = ([a['level']] + others).map do |k|
    d = LEVEL_DEFAULTS[k]
    block = <<~BLOCK
      #{k}:
        review_time_target_days: #{d['review_time_target_days']}   # row 11 clock target
        review_stop_events: [#{d['review_stop_events'].join(', ')}]
        # Row 12 counts a "PR reviewed" artifact more broadly than row 11 clocks a
        # review: a comment is review work even though it does not stop the row-11
        # latency clock. Separate key so changing one KR cannot move the other.
        efficiency_review_events: [#{d['efficiency_review_events'].join(', ')}]
        efficiency_target: #{d['efficiency_target']}
        copilot_target_pct: #{d['copilot_target_pct']}
        mltc_target_days: #{d['mltc_target_days']}
    BLOCK
    block.rstrip.split("\n").map { |line| "  #{line}" }.join("\n")
  end.join("\n")

  <<~YAML
    # okr-monthly configuration — generated by install.rb on #{Date.today}
    # Credentials are NOT stored here. Export them instead:
    #   ATLASSIAN_EMAIL, ATLASSIAN_JIRA_TOKEN, ATLASSIAN_CONFLUENCE_TOKEN,
    #   BITBUCKET_API_TOKEN  (or ATLASSIAN_API_TOKEN as a fallback for all three)
    # Re-run `ruby install.rb --doctor` any time to check what those tokens can read.

    # Per-level OKR targets. The templates differ in both weightage and wording, so
    # nothing here is shared or inferred between levels. L2 is deliberately absent —
    # add a block from its own template rather than reusing L1/L3 numbers.
    # Your level: #{a['level']} (efficiency target #{lvl['efficiency_target']})
    levels:
    #{level_blocks}

    jira:
      site: #{a['site']}    # used for human-readable browse/ links
      # Scoped Atlassian API tokens (the ~192-char kind) are rejected by the site
      # host and must route through the api.atlassian.com gateway, which is keyed by
      # cloud id. Leave blank to talk to the site directly.
      cloud_id: #{a['cloud']}
      # JQL templates — {start} / {end} are replaced with the period dates.
      jql:
        pic_epics: 'issuetype = Epic AND assignee = currentUser() AND statusCategory = Done AND updated >= "{start}" AND updated <= "{end}"'
        tech_debt: 'assignee = currentUser() AND labels in (tech-debt, techdebt, tech_debt) AND updated >= "{start}" AND updated <= "{end}"'
        production_bugs: 'project = #{a['bug_proj']} AND assignee = currentUser() AND created >= "{start}" AND created <= "{end}"'

      # Oncall tickets for the efficiency KR (row 12, stream 4).
      #
      # Scoped by the board's OWN saved filter, so the count always matches what the
      # board shows — including any projects the filter reaches beyond `project`
      # below. A hand-written `project = X` JQL drifts from the board in BOTH
      # directions and is what this key exists to avoid.
      #
      # `filter = {filter}` runs on the platform search API, so no Jira Software
      # board scope is needed. If someone edits the board's filter, this follows it.
      # board_id is kept for the human link only; nothing queries it.
      #
      # {end} is EXCLUSIVE (the day after the week's last day) because Jira reads a
      # bare date as 00:00.
      oncall:
        project: #{a['proj']}
        board_id: #{a['board_id']}#{a['board_id'].to_s.empty? ? '' : "       # #{a['site']}/jira/software/c/projects/#{a['proj']}/boards/#{a['board_id']}"}
        filter_id: #{a['filter_id']}     # the board's saved filter — read off the board, do not hand-edit
        epics:#{yaml_list(a['epics'], 6)}
        jql: 'filter = {filter} AND status CHANGED TO "Done" DURING ("{start}", "{end}")'

    confluence:
      site: #{a['site']}/wiki
      # Docs stream for the efficiency KR. Per-week attribution comes from each
      # page's version history, not from this query — CQL can only filter on a
      # page's LATEST edit.
      docs_cql: 'type = page AND contributor = currentUser() AND lastmodified >= "{start}" AND lastmodified <= "{end}"'
      cql: 'type = page AND contributor = currentUser() AND lastmodified >= "{start}" AND lastmodified <= "{end}"'

    bitbucket:
      workspace: #{a['ws']}
      # Repos scanned for Copilot PR-title markers and for both PR streams.
      copilot_repos:#{yaml_list(a['repos'], 4)}
      mltc:
        # Services: any pipeline whose selector matches this pattern counts as a
        # production deploy.
        service_repos:#{yaml_list(a['svc'], 6)}
        service_pipeline_pattern: '#{a['svc_pat']}'
        # Monolith: releases go out via tag pipelines, so deploys match on these.
        monolith_repos:#{yaml_list(a['mono'], 6)}
        monolith_pipeline_pattern: '#{a['mono_pat']}'
  YAML
end

# =============================================================================
#  MAIN
# =============================================================================
puts bold('okr-monthly installer')
note "config: #{CONFIG_PATH}"
note "ruby:   #{RUBY_VERSION}"

swap = File.join(File.dirname(CONFIG_PATH), ".#{File.basename(CONFIG_PATH)}.swp")
if File.exist?(swap)
  warn_ "#{File.basename(swap)} exists — #{File.basename(CONFIG_PATH)} may be open in vim."
  warn_ 'Saving from that editor would overwrite whatever this script writes.'
  abort "\nClose the editor first (or :e! after this finishes)." unless
    DOCTOR_ONLY || ask_yes('Continue anyway?', false)
end

if DOCTOR_ONLY
  unless File.exist?(CONFIG_PATH)
    abort red("No config at #{CONFIG_PATH} — run `ruby install.rb` first.")
  end
  exit(run_doctor(YAML.load_file(CONFIG_PATH) || {}) ? 0 : 1)
end

miss = missing_credentials
unless miss.empty?
  heading 'Credentials'
  bad "not set: #{miss.join(', ')}"
  note 'install.rb never reads or stores a token value — it only checks what is exported.'
  print_export_help(miss)
  puts
  note 'Without these the interview cannot verify your identity, validate repo slugs,'
  note 'or resolve the oncall board filter.'
  abort "\nNothing written." unless ask_yes('Continue anyway (values will go unverified)?', false)
end

answers = run_interview
rendered = render_config(answers)

heading 'Step 8 — Write config'
if File.exist?(CONFIG_PATH)
  bak = "#{CONFIG_PATH}.bak"
  File.write(bak, File.read(CONFIG_PATH))
  ok "backed up existing config -> #{File.basename(bak)}"
end

new_cfg = YAML.load(rendered)
if !OLD.empty?
  before = flatten_cfg(OLD)
  after  = flatten_cfg(new_cfg)
  dropped = before.keys - after.keys
  changed = (before.keys & after.keys).select { |k| before[k] != after[k] }
  unless dropped.empty?
    puts
    warn_ 'keys in your old config that the template does not carry (re-add by hand if needed):'
    dropped.each { |k| puts "         #{k} = #{before[k]}" }
  end
  unless changed.empty?
    puts
    note 'changed values:'
    changed.each { |k| puts "         #{k}: #{dim(before[k])} -> #{cyan(after[k])}" }
  end
end

puts
unless ask_yes("Write #{File.basename(CONFIG_PATH)}?", true)
  puts "   #{yellow('Not written.')} Nothing changed."
  exit 1
end
File.write(CONFIG_PATH, rendered)
ok "wrote #{CONFIG_PATH}"

healthy = run_doctor(new_cfg)

heading 'Next'
if healthy
  puts "   ruby efficiency.rb  <start> <end>    # pick Monday->Sunday dates"
  puts "   ruby review_time.rb <start> <end> --include-unrequested"
  puts "   ruby copilot.rb     <start> <end>"
  puts "   ruby okr_mltc.rb    <start> <end>"
else
  puts "   Fix the failing checks above, then: #{bold('ruby install.rb --doctor')}"
end
