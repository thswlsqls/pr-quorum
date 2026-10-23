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

exec gh api --method GET "$@"
