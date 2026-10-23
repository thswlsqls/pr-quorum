#!/usr/bin/env bash
# doctor.sh — checks the first-run prerequisites, one line per check. Read-only: starts no session and posts nothing (gh api GETs only).
# The bot token is never read here — the bot login comes from `pr-quorum.sh whoami`, keeping pr-quorum.sh the only reader of bot.env.
# Exit codes: 0 every check passed · 2 at least one FAIL (warnings do not count)
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
source "$HARNESS_DIR/scripts/config.sh"
BOT_ENV="${PR_QUORUM_BOT_ENV:-$HOME/.config/pr-quorum/bot.env}"   # same default as pr-quorum.sh

fails=0
ok()   { echo "ok   — $*"; }
warn() { echo "warn — $*"; }
bad()  { echo "FAIL — $*"; fails=$((fails+1)); }
finish() { [ "$fails" = 0 ] && { echo "doctor — all checks passed"; exit 0; }; echo "doctor — $fails check(s) failed"; exit 2; }

# 1) Commands
for c in claude gh jq git; do
  if command -v "$c" >/dev/null; then ok "command $c"; else bad "command $c not found — install it (README Requirements)"; fi
done
command -v jq >/dev/null || finish   # everything below reads config.json with jq

# 2) config.json and its required keys
if err="$(cfg empty 2>&1)"; then ok "config.json parses"; else bad "$err"; finish; fi
for k in owner bot; do
  if [ -n "$(cfg ".$k // empty | strings")" ]; then ok "config $k = $(cfg ".$k")"; else bad "config.json has no $k — set it (README Setup §3)"; fi
done
if [ "$(cfg '.repos | type == "object" and length > 0')" = true ]; then ok "config repos ($(cfg '.repos | length'))"
else bad "config.json repos must be a non-empty object — README Setup §3"; finish; fi
OWNER="$(cfg '.owner // empty')"; BOT="$(cfg '.bot // empty')"

# 3) Per repository: path is a git repository, profile file exists
for r in $(cfg '.repos | keys[]'); do
  p="$(cfg --arg r "$r" '.repos[$r].path // empty')"
  if [ -n "$p" ] && git -C "$p" rev-parse --git-dir >/dev/null 2>&1; then ok "$r path $p"
  else bad "$r path is not a git repository: ${p:-<unset>} — fix repos.$r.path"; fi
  prof="$(cfg --arg r "$r" '.repos[$r].profile // empty')"
  if [ -n "$prof" ] && [ -f "$PR_QUORUM_HOME/profiles/$prof.md" ]; then ok "$r profile $prof"
  else bad "$r profile file is missing: $PR_QUORUM_HOME/profiles/${prof:-<unset>}.md — README Setup §4"; fi
done

# 4) gh login (the owner's account) — a mismatch with owner is only a warning
if gh auth status >/dev/null 2>&1; then
  me="$(gh api user --jq '.login' 2>/dev/null || true)"
  ok "gh auth status (${me:-?})"
  [ -z "$me" ] || [ "$me" = "$OWNER" ] || warn "gh is logged in as $me, config owner is $OWNER"
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
if login="$("$PR_QUORUM" whoami 2>&1)"; then
  if [ "$login" = "$BOT" ]; then ok "bot token login = $login"; else bad "bot token belongs to $login, config bot is $BOT — fix one of them"; fi
else
  bad "pr-quorum.sh whoami failed: $(tail -1 <<<"$login") — check the token in $BOT_ENV"
fi

# 7) Bot is a collaborator on each repository (owner token; 204 = yes). A pending invitation means the bot has not accepted it
if [ -n "$OWNER" ] && [ -n "$BOT" ]; then
  for r in $(cfg '.repos | keys[]'); do
    if gh api "repos/$OWNER/$r/collaborators/$BOT" >/dev/null 2>&1; then ok "$r bot is a collaborator"
    elif gh api "repos/$OWNER/$r/invitations" --jq '.[].invitee.login' 2>/dev/null | grep -qx "$BOT"; then
      bad "$r bot invitation is pending — sign in as $BOT and accept it"
    else
      bad "$r bot is not a collaborator — invite $BOT with read (README Setup §1)"
    fi
  done
fi

finish
