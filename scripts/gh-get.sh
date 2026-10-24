#!/usr/bin/env bash
# gh-get.sh — the path headless sessions use to read the GitHub API. Takes the same arguments as `gh api` but only sends GET.
# Session permissions block `gh api` entirely and allow only this. Deny rules that match argument positions can be bypassed by reordering or joining arguments (audit S-1).
# Arguments that change the method, body, or request target are rejected; the rest are passed to `gh api --method GET`. With GET, -f becomes a query string.
set -euo pipefail

reject() { echo "gh-get.sh: read-only, does not accept '$1'" >&2; exit 1; }

for a in "$@"; do
  case "$a" in
    # For -X/--method the last value wins, so it would override the --method GET in front. -F reads and sends a local file via @file
    -X*|--method|--method=*|--input|--input=*|-F*|--field|--field=*) reject "$a" ;;
    # Do not send to another host or a full URL. graphql only works over POST
    --hostname|--hostname=*|*://*|graphql) reject "$a" ;;
    *[Mm]ethod-[Oo]verride*) reject "$a" ;;
    # -iXPOST · -iFbody=@x joined after the valueless short option -i
    -i*) [[ "$a" =~ ^-i+[XF] ]] && reject "$a" ;;
  esac
done

# Only this run's repository (chain exports PR_QUORUM_SLUG) or, outside chain, a repository in config.json.
# Text in a PR must not make the session read another repository with the user's gh login (D7). The path comes first, as in the skills
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
ok="$(for r in $(cfg '.repos | keys[]'); do repo_slug "$r"; done)" || exit 2
[ -z "${PR_QUORUM_SLUG:-}" ] || ok="$(grep -Fx -- "$PR_QUORUM_SLUG" <<<"$ok")" || reject "PR_QUORUM_SLUG=$PR_QUORUM_SLUG"
ep="${1:-}"; [[ ! "/$ep/" =~ /\.\.?/ ]] && [[ "$ep" =~ ^repos/([A-Za-z0-9-]+/[A-Za-z0-9._-]+)(/[A-Za-z0-9._-]+)*$ ]] \
  && grep -Fqx -- "${BASH_REMATCH[1]}" <<<"$ok" || reject "$ep"
shift; v=
for a in "$@"; do  # gh api takes one endpoint: no second positional (values of the flags below are skipped)
  if [ -n "$v" ]; then v=; continue; fi
  case "$a" in -H|--header|-q|--jq|-t|--template|-f|--raw-field|-p|--preview|--cache) v=1 ;; --) reject "$a" ;; -*) ;; *) reject "$a" ;; esac
done
set -- "$ep" "$@"

exec gh api --method GET "$@"
