# Shared Bitbucket pull-request scanning for the review-time (KR row 11) and
# efficiency (KR row 12) collectors.
#
# Bitbucket has no workspace-wide "PRs involving user X" endpoint, so both
# collectors scan the configured repo list and filter locally.
require_relative 'common'

BB_API = 'https://api.bitbucket.org/2.0'
PR_STATES = %w[MERGED OPEN DECLINED SUPERSEDED].freeze

def parse_bb_time(str)
  return nil if str.to_s.empty?
  Time.iso8601(str).getlocal
rescue ArgumentError
  begin
    Time.parse(str).getlocal
  rescue StandardError
    nil
  end
end

# PRs in `repo` that were created or touched anywhere in the period. A PR
# created earlier but reviewed inside the period still counts, so the filter is
# on updated_on, not created_on.
def scan_prs(repo, start_date, end_date)
  states = PR_STATES.map { |s| %(state="#{s}") }.join(' OR ')
  q = %((#{states}) AND updated_on>="#{start_date}T00:00:00+00:00" AND created_on<"#{end_date + 1}T00:00:00+00:00")
  prs = []
  bitbucket_each("#{BB_API}/repositories/#{BB_WORKSPACE}/#{repo}/pullrequests",
                 { q: q, pagelen: 50,
                   fields: 'next,values.id,values.title,values.state,values.created_on,' \
                           'values.updated_on,values.author.display_name,values.links.html.href,' \
                           'values.participants.role,values.participants.approved,' \
                           'values.participants.user.display_name' }) do |pr|
    prs << {
      repo: repo,
      id: pr['id'],
      title: pr['title'].to_s,
      state: pr['state'],
      author: pr.dig('author', 'display_name') || 'unknown',
      url: pr.dig('links', 'html', 'href'),
      created_at: parse_bb_time(pr['created_on']),
      participants: (pr['participants'] || []).map do |p|
        { name: p.dig('user', 'display_name'), role: p['role'], approved: p['approved'] }
      end
    }
  end
  prs
end

# One pass over a PR's activity feed, returning [events, requests].
#
# events   — approvals, change requests, declines and comments. The PR author's
#            own comments are dropped; self-comments aren't reviews.
# requests — display_name => [times the user was ADDED as a reviewer]. Bitbucket
#            records these as update entries carrying changes.reviewers.added.
#            Repos with default reviewers fire one at PR creation, so the array
#            is usually a single timestamp ~1s after created_on; a user reviewing
#            without ever being asked has no entry at all.
#
# Both come from the same paginated walk — asking for request times costs no
# extra API calls.
def review_activity(pr)
  events = []
  requests = {}
  url = "#{BB_API}/repositories/#{BB_WORKSPACE}/#{pr[:repo]}/pullrequests/#{pr[:id]}/activity"
  bitbucket_each(url, { pagelen: 50 }) do |act|
    if (ap = act['approval'])
      events << { kind: :approve, user: ap.dig('user', 'display_name'), at: parse_bb_time(ap['date']) }
    elsif (cr = act['changes_requested'])
      events << { kind: :reject, user: cr.dig('user', 'display_name'), at: parse_bb_time(cr['date']) }
    elsif (cm = act['comment'])
      user = cm.dig('user', 'display_name')
      next if user == pr[:author]
      events << { kind: :comment, user: user, at: parse_bb_time(cm['created_on']) }
    elsif (up = act['update'])
      if up['state'] == 'DECLINED'
        events << { kind: :reject, user: up.dig('author', 'display_name'), at: parse_bb_time(up['date']) }
      end
      at = parse_bb_time(up['date'])
      Array(up.dig('changes', 'reviewers', 'added')).each do |u|
        name = u['display_name']
        next if name.nil? || at.nil?
        (requests[name] ||= []) << at
      end
    end
  end
  [events.reject { |e| e[:at].nil? || e[:user].nil? || e[:user] == pr[:author] },
   requests.transform_values(&:sort)]
end

# Events only — kept for callers that don't care who was asked (efficiency.rb).
def review_events(pr)
  review_activity(pr).first
end

def participant?(pr, name)
  pr[:participants].any? { |p| p[:name] == name }
end

def repos_from(argv, key = 'copilot_repos')
  flag_value(argv, 'repos')&.split(',') || CONFIG.dig('bitbucket', key)
end
