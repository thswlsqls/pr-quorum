# config.sh — reads ~/.pr-quorum/config.json. Sourced by the scripts that use its values.
# PR_QUORUM_HOME is fixed so an environment variable cannot change it. This keeps anyone from handing the scripts the session calls (author-push.sh etc.)
# a different config.json to change owner.
PR_QUORUM_HOME="$HOME/.pr-quorum"
# cfg [jq options...] <jq filter> — a missing or broken config.json gets a clear message (exit 2) instead of a raw jq error
cfg() {
  local f="$PR_QUORUM_HOME/config.json"
  [ -f "$f" ] || { echo "config.json is missing: $f (README Setup §3)" >&2; return 2; }
  jq empty "$f" 2>/dev/null || { echo "config.json is not valid JSON: $f" >&2; return 2; }
  jq -r "$@" "$f"
}

# render_settings <plugin root> <template name> — fills the placeholders in templates/<name> and writes $PR_QUORUM_HOME/<name>.
# Permission rules have no variable substitution, so this is rebuilt on every run. Rules like /runs/** resolve relative to ~/.pr-quorum/, where this file lives.
# __AUTHOR_WORKTREES__ is replaced, for each repository in config.json, with an Edit allow rule for <parent of path>/<name>-worktrees/pr-author-*
render_settings() {
  local wt
  wt="$(cfg -c '[.repos | to_entries[] | "Edit(/\(.value.path | sub("/+$"; "") | sub("/[^/]*$"; ""))/\(.key)-worktrees/pr-author-*/**)"]')"
  sed "s|__PLUGIN_ROOT__|$1|g" "$1/templates/$2" \
    | jq --argjson wt "$wt" '.permissions.allow |= [.[] | if . == "__AUTHOR_WORKTREES__" then $wt[] else . end]' \
    > "$PR_QUORUM_HOME/$2"
}
