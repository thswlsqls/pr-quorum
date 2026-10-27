# shellcheck shell=bash
# token-scan.sh — the outgoing check every GitHub write runs first. Sourced by pr-quorum.sh, author-reply.sh, author-push.sh.
# A session that reads a token (a build shell, a grep over ~/.config) could post it as a public comment or push it in a commit
# (improvement plan 02 §1-B). Scripts that write to GitHub refuse a body that contains a token. The matched text is never printed.

# The bot token value from the bot.env file, without sourcing it (shell code in the file does not run). Empty if there is none
bot_token_value() {
  local f="${PR_QUORUM_BOT_ENV:-$HOME/.config/pr-quorum/bot.env}" tok=""
  [ -f "$f" ] || return 0
  tok="$(sed -n 's/^PR_QUORUM_BOT_TOKEN=//p' "$f" | tr -d "\"'" | head -1)"
  [ -n "$tok" ] || tok="$(sed -n 's/^GH_TOKEN=//p' "$f" | tr -d "\"'" | head -1)"
  printf '%s' "$tok"
}

# scan_tokens <file>... — 0 if clean. Otherwise prints which kind of token was found in which file and returns 1.
# Fails closed: a file grep cannot read counts as a hit. Token values reach grep through a pipe, never through argv (ps would show it).
scan_tokens() {
  local f tok name g rc=0 user_tok="" user_read=0
  for f in "$@"; do
    # Patterns first — a hit here refuses without calling gh or reading any token
    g=0; LC_ALL=C grep -aqE '(ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36,}|github_pat_[A-Za-z0-9_]{22,}' "$f" || g=$?
    case $g in
      0) echo "token-scan: $f contains a GitHub token pattern — not sending it" >&2; rc=1; continue ;;
      1) ;;
      *) echo "token-scan: could not read $f — not sending it" >&2; rc=1; continue ;;
    esac
    for name in bot GH_TOKEN GITHUB_TOKEN user; do
      case "$name" in
        bot)          tok="$(bot_token_value)" ;;
        GH_TOKEN)     tok="${GH_TOKEN:-}" ;;
        GITHUB_TOKEN) tok="${GITHUB_TOKEN:-}" ;;
        user)         # The user's gh token, as gh stores it (keychain or hosts.yml). Read once, only when a file got this far
                      [ "$user_read" = 1 ] || { user_tok="$(env -u GH_TOKEN -u GITHUB_TOKEN gh auth token 2>/dev/null || true)"; user_read=1; }
                      tok="$user_tok" ;;
      esac
      [ -n "$tok" ] || continue   # an empty pattern would match every file
      if printf '%s\n' "$tok" | LC_ALL=C grep -aqF -f - "$f"; then
        echo "token-scan: $f contains the $name token value — not sending it" >&2; rc=1; break
      fi
    done
  done
  return "$rc"
}
