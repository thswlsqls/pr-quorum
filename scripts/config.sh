# shellcheck shell=bash
# config.sh — reads ~/.pr-quorum/config.json. Sourced by the scripts that use its values.
# PR_QUORUM_HOME is fixed so an environment variable cannot change it. This keeps anyone from handing the scripts the session calls (author-push.sh etc.)
# a different config.json to change owner.
PR_QUORUM_HOME="$HOME/.pr-quorum"
# need_cmds <cmd>... — exit 2 naming the first command missing from PATH. launchd and cron start with a short PATH
need_cmds() { local c; for c; do command -v "$c" >/dev/null 2>&1 \
  || { echo "$c not found on PATH=$PATH — add its folder to PATH in the launchd plist, crontab, or systemd unit (README Setup §5), or install it (README Requirements)" >&2; return 2; }; done; }
# cfg [jq options...] <jq filter> — a missing or broken config.json gets a clear message (exit 2) instead of a raw jq error
cfg() {
  need_cmds jq || return 2
  local f="$PR_QUORUM_HOME/config.json"
  [ -f "$f" ] || { echo "config.json is missing: $f (README Setup §3)" >&2; return 2; }
  jq empty "$f" 2>/dev/null || { echo "config.json is not valid JSON: $f" >&2; return 2; }
  jq -r "$@" "$f"
}

# pq_mktemp [-d] — a temp file (or folder) under $PR_QUORUM_HOME/tmp. Builds may write $TMPDIR and /private/tmp but not ~/.pr-quorum,
# so a process a build left running cannot rewrite what the harness reads back (harness.md §3-1)
pq_mktemp() { mkdir -p "$PR_QUORUM_HOME/tmp" && mktemp "$@" "$PR_QUORUM_HOME/tmp/pq.XXXXXX"; }

# render_settings <plugin root> <template name> — fills the placeholders in templates/<name> and writes $PR_QUORUM_HOME/<name>.
# Permission rules have no variable substitution, so this is rebuilt on every run. Rules like /runs/** resolve relative to ~/.pr-quorum/, where this file lives.
# __AUTHOR_WORKTREES__ is replaced, for each repository in config.json, with an Edit allow rule for <parent of path>/<name>-worktrees/pr-author-*.
# __REVIEW_WORKTREE_ADD__ · __AUTHOR_WORKTREE_ADD__ become git worktree add allow rules pinned to that same <name>-worktrees/ folder
# (the templates also deny any worktree path with ..), so a session cannot check PR content out anywhere else
render_settings() {
  local wt
  wt="$(cfg -c '[.repos | to_entries[] | (.value.path | sub("/+$"; "") | sub("/[^/]*$"; "")) as $p
    | {edit: "Edit(/\($p)/\(.key)-worktrees/pr-author-*/**)",
       review: "Bash(git worktree add --detach \($p)/\(.key)-worktrees/*)",
       author: "Bash(git worktree add \($p)/\(.key)-worktrees/pr-author-*)"}]')"
  sed "s|__PLUGIN_ROOT__|$1|g" "$1/templates/$2" \
    | jq --argjson wt "$wt" '.permissions.allow |= [.[]
        | if . == "__AUTHOR_WORKTREES__" then $wt[].edit
          elif . == "__REVIEW_WORKTREE_ADD__" then $wt[].review
          elif . == "__AUTHOR_WORKTREE_ADD__" then $wt[].author else . end]' \
    > "$PR_QUORUM_HOME/$2"
}

# repo_slug <repo> — prints <owner>/<repo> for GitHub API paths. owner is repos.<repo>.owner, falling back to the top-level owner.
# Every script builds its repos/<owner>/<repo> paths from this, so one config.json can hold a personal repository and an organization's side by side
repo_slug() {
  local o
  o="$(cfg --arg r "$1" '.repos[$r].owner // .owner // empty')" || return 2
  [[ "$o" =~ ^[A-Za-z0-9-]+$ ]] || { echo "no valid owner for $1: set owner or repos.$1.owner in $PR_QUORUM_HOME/config.json" >&2; return 2; }
  echo "$o/$1"
}

# Trust — which PR authors may run the chain, which pushes and merges under the user's gh account.
# A PR runs only if its author's login is in trust.authors or its author_association is in trust.associations (default ["OWNER"]).
# Someone else's PR description and diff would go straight into those sessions (prompt injection), so the default trusts only the owner.
# Trust comes only from config.json and the GitHub API, never from arguments, environment variables, or the PR itself.
TRUST_KNOWN='"COLLABORATOR","CONTRIBUTOR","FIRST_TIMER","FIRST_TIME_CONTRIBUTOR","MANNEQUIN","MEMBER","NONE","OWNER"'  # REST author_association values

# trust_check [--quiet] — exit 2 if trust is malformed or trust.associations holds a value GitHub does not use.
# Without --quiet, also warns when trust.associations goes beyond OWNER, MEMBER, COLLABORATOR — the rest are people with no write access
trust_check() {
  local err wide
  err="$(cfg '(.trust // {}) as $t
    | if ($t | type) != "object" then "trust must be an object"
      elif ($t.authors // [] | type != "array" or any(.[]; type != "string")) then "trust.authors must be a list of logins"
      elif ($t.associations // ["OWNER"] | type != "array" or any(.[]; type != "string")) then "trust.associations must be a list"
      else [$t.associations // ["OWNER"] | .[] | select(IN('"$TRUST_KNOWN"') | not)] | join(", ")
        | if . == "" then empty else "trust.associations has values GitHub does not use: \(.) (allowed: '"${TRUST_KNOWN//\"/}"')" end
      end')" || return 2
  [ -z "$err" ] || { echo "config.json: $err" >&2; return 2; }
  [ "${1:-}" = --quiet ] && return 0
  wide="$(cfg '[.trust.associations // ["OWNER"] | .[] | select(IN("OWNER","MEMBER","COLLABORATOR") | not)] | join(", ")')"
  [ -z "$wide" ] || echo "warning — trust.associations includes $wide: PRs from people with no write access will push and merge under your account" >&2
}

# is_trusted <login> <author_association> — 0 trusted · 1 not trusted · 2 trust config is invalid. Logins compare case-insensitively, as GitHub does
is_trusted() {
  local r
  trust_check --quiet || return 2
  r="$(cfg --arg l "$1" --arg a "$2" '($l | ascii_downcase) as $l
    | ($l != "" and any(.trust.authors // [] | .[]; ascii_downcase == $l)) or any(.trust.associations // ["OWNER"] | .[]; . == $a)')" || return 2
  [ "$r" = true ]
}

# require_dotcom — only github.com is supported. On another GH_HOST, gh uses GH_ENTERPRISE_TOKEN instead of GH_TOKEN, so the bot token
# would be ignored and posts could go out under the user's stored credentials. Exit 2 before anything is read or posted
require_dotcom() {
  [ -z "${GH_HOST:-}" ] || [ "$GH_HOST" = github.com ] \
    || { echo "GH_HOST=$GH_HOST — pr-quorum supports only github.com (not GitHub Enterprise Server or ghe.com). Unset GH_HOST" >&2; exit 2; }
}
