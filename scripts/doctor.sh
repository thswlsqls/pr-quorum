#!/usr/bin/env bash
# doctor.sh — checks the first-run prerequisites, one line per check. Read-only: starts no session and posts nothing (gh api GETs only).
# The bot token is never read here — the bot login comes from `pr-quorum.sh whoami`, keeping pr-quorum.sh the only reader of bot.env.
# Exit codes: 0 every check passed · 2 at least one FAIL (warnings do not count)
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
source "$HARNESS_DIR/scripts/config.sh"
source "$HARNESS_DIR/scripts/build-sandbox.sh"
require_dotcom
BOT_ENV="${PR_QUORUM_BOT_ENV:-$HOME/.config/pr-quorum/bot.env}"   # same default as pr-quorum.sh

fails=0
ok()   { echo "ok   — $*"; }
warn() { echo "warn — $*"; }
bad()  { echo "FAIL — $*"; fails=$((fails+1)); }
finish() { [ "$fails" = 0 ] && { echo "doctor — all checks passed"; exit 0; }; echo "doctor — $fails check(s) failed"; exit 2; }

# --init <repo path> — writes config.json from templates/config.json when there is none, adds the missing state files, then runs the checks: owner = the gh login,
# bot = the token's login (pr-quorum.sh whoami), one repository named after origin with its path and origin's owner. Nothing is written unless all are found
if [ "${1:-}" = --init ]; then
  [ -n "${2:-}" ] || { echo "usage: doctor.sh [--init <repo path>]" >&2; exit 2; }
  if [ -e "$PR_QUORUM_HOME/config.json" ]; then warn "config.json exists, left as is: $PR_QUORUM_HOME/config.json"
  else
    # Only a github.com origin, with the owner pattern repo_slug accepts — another host would write a config no check can pass
    u="$(git -C "$2" remote get-url origin 2>/dev/null)"; u="${u%/}"; u="${u%.git}"; o="" n=""
    re='^(https://([^@/]*@)?|ssh://git@|git@)github\.com[:/]([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$'
    [[ "$u" =~ $re ]] && { o="${BASH_REMATCH[3]}"; n="${BASH_REMATCH[4]}"; }
    p="$(git -C "$2" rev-parse --show-toplevel 2>/dev/null)"
    me="$(gh api user --jq '.login' 2>/dev/null)"; b="$("$PR_QUORUM" whoami 2>/dev/null)"
    miss=""
    [ -n "$n" ] || miss="$miss, a github.com origin URL in $2"
    [ -n "$p" ] || miss="$miss, git repository at $2"
    [ -n "$me" ] || miss="$miss, gh login (gh auth login)"
    [ -n "$b" ] || miss="$miss, bot login (pr-quorum.sh whoami, README Setup §2)"
    [ -z "$miss" ] && j="$(jq --arg me "$me" --arg b "$b" --arg n "$n" --arg o "$o" --arg p "$p" \
      '.owner = $me | .bot = $b | .repos = {($n): (.repos["your-repo"] | .path = $p | .owner = $o)}' "$HARNESS_DIR/templates/config.json")" \
      && mkdir -p "$PR_QUORUM_HOME" && (set -C; printf '%s\n' "$j" > "$PR_QUORUM_HOME/config.json") 2>/dev/null \
      && ok "config.json written: owner $me, bot $b, repos.$n $p" || { [ -n "$miss" ] && miss="could not get ${miss#, }" || miss="could not write $PR_QUORUM_HOME/config.json"
           bad "--init wrote nothing — $miss"; finish; }
  fi
  # The rest of ~/.pr-quorum: profiles/ with the generic sample (the template's profile), learnings.md, human-labels.md. Nothing is overwritten
  if mkdir -p "$PR_QUORUM_HOME/profiles" && touch "$PR_QUORUM_HOME/learnings.md" "$PR_QUORUM_HOME/human-labels.md"; then
    [ -e "$PR_QUORUM_HOME/profiles/generic.md" ] || { cp "$HARNESS_DIR/examples/profiles/generic.md" "$PR_QUORUM_HOME/profiles/generic.md" \
      && ok "profiles/generic.md copied from examples — fill in its <fill in> lines" || bad "could not copy profiles/generic.md"; }
  else bad "could not create profiles/, learnings.md or human-labels.md in $PR_QUORUM_HOME"; fi
fi

# 1) Commands
for c in claude gh jq git; do
  if command -v "$c" >/dev/null; then ok "command $c ($(dirname "$(command -v "$c")"))"; else bad "command $c not found — install it (README Requirements)"; fi
done
# Session templates set permissions.blockReadsOutsideWorkingDirectories, which needs Claude Code 2.1.257 or later
if command -v claude >/dev/null; then
  cv="$(claude --version 2>/dev/null | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
  if [ -n "$cv" ] && awk -v v="$cv" 'BEGIN { split(v, a, "."); exit !(a[1] > 2 || (a[1] == 2 && (a[2] > 1 || (a[2] == 1 && a[3] >= 257)))) }'; then
    ok "claude version $cv"
  else bad "claude version ${cv:-unknown} — 2.1.257 or later is needed (blockReadsOutsideWorkingDirectories)"; fi
fi
# chain.sh turns off repository hooks in sessions through GIT_CONFIG_COUNT (git 2.31+) and stops with exit 2 without it
if command -v git >/dev/null; then
  if [ "$(GIT_CONFIG_COUNT=1 GIT_CONFIG_KEY_0=pq.probe GIT_CONFIG_VALUE_0=1 git config --get pq.probe 2>/dev/null)" = 1 ]; then ok "git reads GIT_CONFIG_COUNT"
  else bad "$(git --version) — 2.31 or later is needed (GIT_CONFIG_COUNT turns off repository hooks in chain sessions)"; fi
fi
command -v jq >/dev/null || finish   # everything below reads config.json with jq

# 2) config.json and its required keys
if err="$(cfg empty 2>&1)"; then ok "config.json parses"; else bad "$err"; finish; fi
for k in owner bot; do
  v="$(cfg ".$k // empty | strings")"
  case "$v" in
    "") bad "config.json has no $k — set it (README Setup §3)" ;;
    your-github-login|your-bot-login|__OWNER__|__BOT__) ;;   # reported with the other template values below
    *) ok "config $k = $v" ;;
  esac
done
# Values copied from templates/config.json and never replaced — listed once, keys first, in the order they appear
tv="$(cfg '[(.owner, .bot | strings), (.repos | objects | keys[]), (.. | strings)]
  | map(select(test("^your-(github|bot)-login$|^your-repo$|^/absolute/path/to/|^__(OWNER|BOT|REPO_PATH)__$")))
  | reduce .[] as $v ([]; if index([$v]) then . else . + [$v] end) | join(", ")')"
[ -z "$tv" ] || bad "config.json still has template values: $tv — replace them (README Setup §3)"
if [ "$(cfg '.repos | type == "object" and length > 0')" = true ]; then ok "config repos ($(cfg '.repos | length'))"
else bad "config.json repos must be a non-empty object — README Setup §3"; finish; fi
OWNER="$(cfg '.owner // empty')"; BOT="$(cfg '.bot // empty')"
# The bot posts reviews and is the requested reviewer the watcher looks for, so it has to be a second account (logins are case-insensitive)
[ -z "$BOT" ] || [ "$(tr A-Z a-z <<<"$BOT")" != "$(tr A-Z a-z <<<"$OWNER")" ] || bad "config bot is the owner ($BOT) — the bot must be a second GitHub account (README Setup §1)"
# limits — a missing one means no cap, which is allowed. budget_usd goes to claude --max-budget-usd as read ("25" works), so it must read as a number
[ "$(cfg '.limits | type')" = object ] || warn "no limits: a session has no cost cap"
for k in $(cfg '.limits | objects | to_entries[] | select(.value | objects | has("budget_usd") and (.budget_usd | tostring | test("^[0-9]+(\\.[0-9]+)?$") | not)) | .key'); do
  bad "limits.$k.budget_usd is not a number"
done
# trust — who may run the chain. A warning (associations beyond OWNER, MEMBER, COLLABORATOR) does not fail
if err="$(trust_check 2>&1)"; then
  ok "config trust (authors: $(cfg '.trust.authors // [] | join(", ") | if . == "" then "-" else . end'); associations: $(cfg '.trust.associations // ["OWNER"] | join(", ")'))"
  [ -z "$err" ] || warn "${err#warning — }"
else
  bad "$err"
fi

# 3) Per repository: owner resolves (repos.<name>.owner, else owner), path is a git repository, profile file exists and is not a bare sample,
# and each of repos.<name>.commands can start in path (commands turn off auto-detection, so a wrong one fails every Stage 3 measurement)
for r in $(cfg '.repos | keys[]'); do
  if slug="$(repo_slug "$r" 2>&1)"; then ok "$r owner ${slug%/*}"; else bad "$slug"; fi
  p="$(cfg --arg r "$r" '.repos[$r].path // empty')"
  if [ -n "$p" ] && [[ "$p" != /* ]]; then bad "$r path is not absolute: $p — repos.$r.path must start with /"; pok=""
  elif [ -n "$p" ] && git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then ok "$r path $p"; pok=1
  else bad "$r path is not a git repository: ${p:-<unset>} — fix repos.$r.path"; pok=""; fi
  prof="$(cfg --arg r "$r" '.repos[$r].profile // empty')"
  if [ -n "$prof" ] && [ -f "$PR_QUORUM_HOME/profiles/$prof.md" ]; then
    ok "$r profile $prof"
    for s in "$HARNESS_DIR"/examples/profiles/*.md; do   # a sample still runs, with another project's context — a warning
      cmp -s "$s" "$PR_QUORUM_HOME/profiles/$prof.md" \
        && warn "$r profile $prof is an unmodified copy of examples/profiles/${s##*/} — rewrite §0 and §6 for this repository"
    done
    n="$(grep -c '<fill in' "$PR_QUORUM_HOME/profiles/$prof.md")"
    [ "$n" = 0 ] || warn "$r profile $prof has $n placeholder(s) left — replace the <fill in: …> lines"
  else bad "$r profile file is missing: $PR_QUORUM_HOME/profiles/${prof:-<unset>}.md — README Setup §4"; fi
  # always_human — optional path prefixes that always go to a person (rules/03-risk.md). Anything but a list of strings makes risk scoring fail
  [ "$(cfg --arg r "$r" '.repos[$r] | (has("always_human") | not) or (.always_human | type == "array" and all(type == "string"))')" = true ] \
    || bad "$r always_human is not a list of path prefixes — repos.$r.always_human must look like [\"src/billing/\"]"
  # ./X must exist in path (commands run at the worktree root). npm and friends often run in a subfolder (--prefix, cd app), so only a warning
  [ -n "$pok" ] || continue
  while IFS=$'\t' read -r k c; do
    w="${c%% *}"
    case "$w" in
      ./*) [ -e "$p/${w#./}" ] || bad "$r commands.$k runs $w, but $p has no ${w#./} — fix it, or delete commands to use auto-detection (README Setup §3)" ;;
      npm|npx|pnpm|yarn) [ -f "$p/package.json" ] \
        || warn "$r commands.$k runs $w, but $p has no package.json — check it, or delete commands to use auto-detection (README Setup §3)" ;;
    esac
  done < <(cfg --arg r "$r" '.repos[$r].commands // {} | to_entries[] | "\(.key)\t\(.value)"')
  # Without commands, build and test are auto-detected from gradlew or package.json (pr-quorum.sh build)
  [ "$(cfg --arg r "$r" '.repos[$r].commands | type')" = object ] || [ -f "$p/gradlew" ] || [ -f "$p/package.json" ] \
    || warn "$r has no commands and no gradlew or package.json: builds and tests will be \"not measured\""
done

# 4) gh login (the owner's account) — a mismatch with owner is only a warning
if gh auth status >/dev/null 2>&1; then
  me="$(gh api user --jq '.login' 2>/dev/null || true)"
  ok "gh auth status (${me:-?})"
  [ -z "$me" ] || [ "$me" = "$OWNER" ] || warn "gh is logged in as $me, config owner is $OWNER"
  # In another owner's repository (an organization) GitHub marks your own PRs MEMBER, not OWNER, so default trust skips them
  for r in $(cfg '.repos | keys[]'); do
    o="$(repo_slug "$r" 2>/dev/null)" || continue; o="${o%/*}"
    [ -z "$me" ] || [ "$(tr A-Z a-z <<<"$o")" = "$(tr A-Z a-z <<<"$me")" ] || is_trusted "$me" MEMBER 2>/dev/null \
      || warn "$r belongs to $o, where your PRs come as MEMBER and are skipped — add \"$me\" to trust.authors"
  done
else
  bad "gh is not logged in — run gh auth login"
fi

# 5) Bot token file — exists and is mode 600. ls -ln instead of stat (BSD and GNU stat flags differ)
if [ -f "$BOT_ENV" ]; then
  mode="$(ls -ln "$BOT_ENV" | cut -c1-10)"
  if [ "$mode" = "-rw-------" ]; then ok "bot.env mode 600"; else bad "bot.env mode is $mode — chmod 600 $BOT_ENV"; fi
else
  bad "bot token file is missing: $BOT_ENV — README Setup §2"
fi

# 6) The token's account is config bot — otherwise the watcher polls as the wrong account and never fires
botok=""
if login="$("$PR_QUORUM" whoami 2>&1)"; then
  botok=1
  if [ "$login" = "$BOT" ]; then ok "bot token login = $login"; else bad "bot token belongs to $login, config bot is $BOT — fix one of them"; fi
else
  bad "pr-quorum.sh whoami failed: $(tail -1 <<<"$login") — check the token in $BOT_ENV"
fi

# 7) Bot is a collaborator on each repository (gh login token, per-repository owner; 204 = yes). A pending invitation means the bot has not accepted it
if [ -n "$BOT" ]; then
  for r in $(cfg '.repos | keys[]'); do
    slug="$(repo_slug "$r" 2>/dev/null)" || continue   # already reported in 3)
    # The repository first — a typo, a login that cannot see it, and a network error are not "not a collaborator"
    if ! e="$(gh api "repos/$slug" --silent 2>&1)"; then
      case "$e" in
        *"HTTP 404"*) bad "$r repository $slug not found, or the gh login cannot see it — check the repos key and owner" ;;
        *) bad "$r cannot reach GitHub for $slug: $(tail -1 <<<"$e")" ;;
      esac
      continue
    fi
    if e="$(gh api "repos/$slug/collaborators/$BOT" 2>&1 >/dev/null)"; then ok "$r bot is a collaborator"
      # A collaborator its token still cannot see: a classic token with only public_repo cannot read a private repository
      [ -z "$botok" ] || e="$("$PR_QUORUM" whoami "$r" 2>&1 >/dev/null)" || case "$e" in
        *"HTTP 404"*) bad "$r bot token cannot read $slug (a private repository needs scope repo — README Setup §2)" ;;
        *) bad "$r bot token cannot reach GitHub for $slug: $(tail -1 <<<"$e")" ;;
      esac
    elif [[ "$e" != *"HTTP 404"* ]]; then bad "$r cannot check collaborator $BOT on $slug: $(tail -1 <<<"$e")"
    elif gh api "repos/$slug/invitations" --jq '.[].invitee.login' 2>/dev/null | grep -qx "$BOT"; then
      bad "$r bot invitation is pending — sign in as $BOT and accept it"
    else
      bad "$r bot is not a collaborator — invite $BOT (README Setup §1)"
    fi
  done
fi

# 8) Build sandbox — with build.sandbox "require" (the default) builds refuse to run without one, so every measurement would be "not measured"
sb="$(cfg '.build.sandbox // "require"')"; kind="$(sandbox_kind)"
if [ "$sb" = off ]; then
  warn "build.sandbox is off — builds run with your environment and can read your credentials (docs/harness.md §3-1)"
elif [ "$sb" != require ]; then
  bad "build.sandbox must be \"require\" or \"off\": $sb"
elif [ -z "$kind" ]; then
  case "$(uname -s)" in
    Darwin) bad "build sandbox: sandbox-exec not found — it ships with macOS at /usr/bin/sandbox-exec; check PATH" ;;
    *)      bad "build sandbox: bwrap not found — install bubblewrap (apt install bubblewrap · dnf install bubblewrap), or set build.sandbox \"off\"" ;;
  esac
elif sandbox_check "$kind"; then
  ok "build sandbox $kind"
else
  if [ "$kind" = bwrap ]; then
    bad "build sandbox bwrap does not start — on Ubuntu 24.04+ allow unprivileged user namespaces for it (https://code.claude.com/docs/en/sandboxing#set-up-linux-and-wsl2), or set build.sandbox \"off\""
  else
    bad "build sandbox seatbelt does not start — sandbox-exec could not run true; run it by hand to see why, or set build.sandbox \"off\""
  fi
fi
for n in $(cfg '.build.env_passthrough // [] | .[]'); do
  sandbox_env_ok "$n" || bad "build.env_passthrough refuses $n — not a variable name, or looks like a credential (*TOKEN*, *SECRET*, *KEY*, PR_QUORUM_*)"
done

finish
