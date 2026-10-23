#!/usr/bin/env bash
# selftest.sh — reruns pr-quorum.sh's mechanical gates (PG5, PG6) on real past outputs. Uses no LLM.
# Run it once after changing a gate script. If an already-posted output fails the new rule, the rule is most likely wrong
# (PR #38 was blocked from posting by the axis regex R-[A-H] alone — L0-31).
# ~/.pr-quorum/runs lives outside the repository, so it exists only on this machine. Skip if it is missing.
set -uo pipefail

HARNESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PR_QUORUM="$HARNESS_DIR/scripts/pr-quorum.sh"
source "$HARNESS_DIR/scripts/config.sh"
RUNS="$PR_QUORUM_HOME/runs"

pass=0; fail=0
check() {  # check <name> <command...>
  local name="$1" out; shift
  if out="$("$@" 2>&1)"; then pass=$((pass+1)); else
    fail=$((fail+1)); echo "FAIL — $name"; sed 's/^/    /' <<<"$out"
  fi
}

# risk.jq — document classification (rules/03-risk.md). One file, 400 added lines. Needs no network and no runs/
risk_score() {  # risk_score <filename> <expected score>
  local got
  got="$(jq -nc --arg f "$1" '[{filename:$f, additions:400, deletions:0, patch:"+x"}]' \
        | jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" | jq -r .score)" || return 1
  [ "$got" = "$2" ] || { echo "$1: expected $2, got $got"; return 1; }
}
check "risk doc top-level docs/"     risk_score "docs/guide.md" 0
check "risk doc contents/ image"     risk_score "contents/api-auth/flow.png" 0
check "risk doc contents/ .mmd"      risk_score "contents/api-auth/flow.mmd" 0
check "risk doc nested .md"          risk_score "api/auth/docs/design.md" 0
check "risk code under nested docs/" risk_score "src/main/java/com/acme/docs/auth/JwtAuthFilter.java" 40
check "risk code under contents/"    risk_score "src/main/java/com/acme/contents/auth/JwtAuthFilter.java" 40
check "risk harness rule .md"        risk_score "rules/03-risk.md" 15
# Every plugin script must hit the harness signal — risk.jq lists them by name, so a new script left off that list would auto-merge at 0 points
harness_hit() {  # harness_hit <filename>
  jq -nc --arg f "$1" '[{filename:$f, additions:1, deletions:0, patch:"+x"}]' \
    | jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" \
    | jq -e '[.categories[].signals[] | select(.name == "Auto-merge gate/harness") | .points] | add == 15' >/dev/null \
    || { echo "$1 is not in the harness name list of scripts/risk.jq and rules/03-risk.md"; return 1; }
}
for s in "$HARNESS_DIR"/scripts/*; do
  check "risk harness list has $(basename "$s")" harness_hit "scripts/$(basename "$s")"
done
# Build and dependency files of other stacks (rules/03-risk.md) — build script 15 + dependencies 15 + scope 10, or dependencies 15 + scope 10
check "risk Maven pom.xml"           risk_score "pom.xml" 40
check "risk Python pyproject.toml"   risk_score "pyproject.toml" 40
check "risk Python requirements"     risk_score "requirements-dev.txt" 25
check "risk Go go.mod"               risk_score "go.mod" 25
check "risk Rust Cargo.lock"         risk_score "Cargo.lock" 25
# Test files of other stacks count as tests — no production signal and no scope points
check "risk Go test file"            risk_score "pkg/auth/token_test.go" 0
check "risk Python test file"        risk_score "tests/test_api.py" 0
check "risk Go code without tests"   risk_score "pkg/store/store.go" 25
# Dependency-only PRs, files run at build or test time, and renames out of a sensitive path (rules/03-risk.md)
risk_json() {  # risk_json <files JSON> <expected score> — for multi-file and rename cases
  local got; got="$(jq --arg sha t --arg at t -f "$HARNESS_DIR/scripts/risk.jq" <<<"$1" | jq -r .score)" || return 1
  [ "$got" = "$2" ] || { echo "expected $2, got $got"; return 1; }
}
check "risk lock file only"          risk_score "package-lock.json" 15
check "risk small manifest bump"     risk_json '[{"filename":"go.mod","additions":1,"deletions":1,"patch":"+x"}]' 15
check "risk .npmrc"                  risk_score ".npmrc" 25
check "risk Makefile"                risk_score "Makefile" 25
check "risk build config with tests" risk_json '[{"filename":"vite.config.ts","additions":30,"deletions":0,"patch":"+x"},{"filename":"src/__tests__/a.test.ts","additions":1,"deletions":0}]' 15
check "risk buildSrc with tests"     risk_json '[{"filename":"buildSrc/src/main/kotlin/Conv.kt","additions":30,"deletions":0,"patch":"+x"},{"filename":"src/test/x/ATest.java","additions":1,"deletions":0}]' 15
check "risk .npmrc token"            risk_json '[{"filename":".npmrc","additions":1,"deletions":0,"patch":"+//registry.npmjs.org/:_authToken=npm_abcdefgh1234"}]' 30
check "risk rename out of auth"      risk_json '[{"filename":"src/main/java/a/Moved.java","previous_filename":"src/main/java/a/JwtAuthFilter.java","status":"renamed","additions":0,"deletions":0}]' 15
check "risk rename out of harness"   risk_json '[{"filename":"lib/risk.jq","previous_filename":"scripts/risk.jq","status":"renamed","additions":0,"deletions":0}]' 15
check "risk doc rename stays 0"      risk_json '[{"filename":"docs/a.md","previous_filename":"docs/b.md","status":"renamed","additions":0,"deletions":0}]' 0
for f in .github/actions/setup/action.yml action.yml .husky/pre-commit .pre-commit-config.yaml tox.ini build.rs .mcp.json .github/CODEOWNERS mcp.json; do
  check "risk build/agent file $f" risk_score "$f" 25   # signal 15 + scope 10 (risk_score is 400 lines)
done
check "risk CLAUDE.local.md"      risk_score "CLAUDE.local.md" 15   # .md: no scope lines
check "risk CODEOWNERS removed"   risk_json '[{"filename":".github/CODEOWNERS","status":"removed","additions":0,"deletions":3}]' 15
check "risk noxfile with tests"   risk_json '[{"filename":"noxfile.py","additions":30,"deletions":0,"patch":"+x"},{"filename":"tests/test_a.py","additions":1,"deletions":0}]' 15
check "risk toml secret"          risk_json '[{"filename":"config/settings.toml","additions":1,"deletions":0,"patch":"+api_key = \"sk_live_abcdefgh1234\""}]' 30
check "risk ini secret"           risk_json '[{"filename":"config/app.ini","additions":1,"deletions":0,"patch":"+password = hunter2hunter2"}]' 30
check "risk cfg secret"           risk_json '[{"filename":"setup.cfg","additions":1,"deletions":0,"patch":"+api_key = \"sk_live_abcdefgh1234\""}]' 30
check "risk nested mcp.json stays" risk_score "examples/mcp.json" 10   # scope only
check "risk nested action.yml stays" risk_score "tools/x/action.yml" 10   # only root and .github/ action.yml count

# Credential Read deny — the three session templates must deny the same list (dream alone also denies ~/.claude/** and docs/)
cred_deny() {  # cred_deny <template> — its Read deny rules minus the dream-only ones, sorted
  jq -c '[.permissions.deny[] | select(startswith("Read(")) | select(IN("Read(~/.claude/**)", "Read(/__PLUGIN_ROOT__/docs/**)") | not)] | sort' \
    "$HARNESS_DIR/templates/$1"
}
same_cred_deny() {
  local s a d; s="$(cred_deny settings.json)"; a="$(cred_deny author-settings.json)"; d="$(cred_deny dream-settings.json)"
  [ "$s" != "[]" ] && [ "$s" = "$a" ] && [ "$s" = "$d" ] || { printf 'settings: %s\nauthor:   %s\ndream:    %s\n' "$s" "$a" "$d"; return 1; }
}
check "templates share the credential Read deny" same_cred_deny

# Translated READMEs record the README.md commit they follow. Warn only — a lagging translation does not change review behavior
for t in "$HARNESS_DIR"/README.*.md; do
  [ -f "$t" ] || continue
  base="$(grep -oE '@ `[0-9a-f]{7,40}`' "$t" | head -1 | tr -d '@` ')"
  n="$(git -C "$HARNESS_DIR" rev-list --count "$base..HEAD" -- README.md 2>/dev/null)" && [ -n "$base" ] || n="?"
  [ "$n" = 0 ] || echo "warning — $(basename "$t") is $n commit(s) behind README.md (base ${base:-missing})"
done

# Fake GitHub — post-review idempotency (T1–T5) and worktree GC (G1–G4). No network and no real ~/.pr-quorum:
# each case runs the script in a subshell with HOME set to a temp folder and a stub gh first on PATH.
# The stub logs one line per call to $STUB/state/calls.log and takes injected failures from files in $STUB/state/
STUB="$(mktemp -d)"; trap 'rm -rf "$STUB"' EXIT
STUB_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
STUB_RUN="$STUB/home/.pr-quorum/runs/demo-pr1"
mkdir -p "$STUB/bin"
cat > "$STUB/bin/gh" <<'GH'
#!/usr/bin/env bash
S="$STUB_STATE"; echo "$*" >> "$S/calls.log"
# take <file>: one injected result per line, each call consumes one — "ok" lets that call through, anything else is its error
take() {
  [ -s "$S/$1" ] || return 0
  local l; l="$(head -1 "$S/$1")"; tail -n +2 "$S/$1" > "$S/t"; mv "$S/t" "$S/$1"
  [ "$l" = ok ] || { echo "$l" >&2; exit 1; }
}
case "$1" in
  auth) exit 1 ;;                 # token-scan asks for the user's token — there is none
  search) echo '[]'; exit 0 ;;    # watch.sh --once: no review requests
  pr)
    # chain.sh tests (C1–C3): an open, mergeable PR; fail-prview injects failures into the mergeable lookup
    if [ -e "$S/chain" ]; then
      case "$*" in *"--json state,isDraft,mergeable"*) take fail-prview; echo '{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE"}' ;; *) echo OPEN ;; esac
      exit 0
    fi
    case "$3" in 1) echo MERGED ;; 2) echo CLOSED ;; 3) echo OPEN ;; *) echo "HTTP 404: Not Found" >&2; exit 1 ;; esac; exit 0 ;;
  api) shift ;;
  *) exit 1 ;;
esac
path="" input="" q=""
while [ $# -gt 0 ]; do
  case "$1" in --input) input="$2"; shift 2 ;; --jq) q="$2"; shift 2 ;; -*) shift ;; *) path="$1"; shift ;; esac
done
out() { if [ -n "$q" ]; then jq -r "$q"; else cat; fi; }
case "$path" in
  */pulls/1)
    take fail-pr
    echo '{"head":{"sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"},"base":{"sha":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"},"changed_files":1,"additions":3,"deletions":0,"user":{"login":"alice"},"author_association":"OWNER"}' | out ;;
  */compare/*) jq -n '{files:[{filename:"src/a.txt", patch:"@@ -0,0 +1,3 @@\n+a\n+b\n+c"}]}' | out ;;
  */pulls/1/reviews)
    [ -n "$input" ] || { cat "$S/reviews.json"; exit 0; }
    # The server creates the review and its comments first — fail-post then loses only the response
    n=$(( $(cat "$S/posts") + 1 )); echo "$n" > "$S/posts"; id=$((110 + n))
    jq --argjson id "$id" --slurpfile p "$input" '. + [{id:$id, user:{login:"quorum-bot"}, commit_id:$p[0].commit_id, body:$p[0].body}]' \
      "$S/reviews.json" > "$S/t" && mv "$S/t" "$S/reviews.json"
    jq --argjson id "$id" --slurpfile p "$input" '. + [$p[0].comments | to_entries[] | .value + {id:(1000 * $id + .key), pull_request_review_id:$id}]' \
      "$S/comments.json" > "$S/t" && mv "$S/t" "$S/comments.json"
    [ ! -e "$S/fail-post" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    echo "{\"id\":$id}" | out ;;
  */pulls/1/comments)
    [ ! -e "$S/fail-comments" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    cat "$S/comments.json" ;;
  */issues/1/comments) cat > /dev/null; echo '{"id":5}' | out ;;
  repos/acme/demo)
    [ ! -e "$S/fail-repo" ] || { echo "HTTP 502: Bad Gateway" >&2; exit 1; }
    echo "HTTP 404: Not Found" >&2; exit 1 ;;
  *) echo "HTTP 404: Not Found" >&2; exit 1 ;;
esac
GH
chmod +x "$STUB/bin/gh"
# No test may start a session — a claude call is logged and fails instead of reaching the real one further down PATH
printf '#!/usr/bin/env bash\necho "claude $*" >> "$STUB_STATE/calls.log"; exit 1\n' > "$STUB/bin/claude"
chmod +x "$STUB/bin/claude"

stub_home() {  # a fresh fake HOME: config.json (repo demo), bot.env, and runs/demo-pr1 with a stage1 draft that passes PG1 and PG5
  rm -rf "$STUB/home" "$STUB/state"
  mkdir -p "$STUB_RUN/outputs/stage1" "$STUB_RUN/outputs/stage3" "$STUB/home/.config/pr-quorum" "$STUB/state"
  jq -n --arg p "$STUB/repo/demo" '{owner:"acme", bot:"quorum-bot", repos:{demo:{path:$p, profile:"backend"}}}' > "$STUB/home/.pr-quorum/config.json"
  echo PR_QUORUM_BOT_TOKEN=test-token > "$STUB/home/.config/pr-quorum/bot.env"
  jq -n --arg h "$STUB_SHA" '{owner:"acme", repo:"demo", pr:1, base_sha:"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", eval_sha:$h, profile:"backend",
                             lock:null, attempts:0, stage1:[], stage2:[], stage3:null, status:"pending"}' > "$STUB_RUN/meta.json"
  printf '## Summary\n\npraise — the names read well.\n\nAxes: `R-A` Correctness\n' > "$STUB_RUN/outputs/stage1/summary.md"
  echo '[{"code":"S1-1","path":"src/a.txt","line":2,"side":"RIGHT","axis":"R-A","grade":"minor","body":"R-A (Correctness) — b looks off."}]' \
    > "$STUB_RUN/outputs/stage1/comments.json"
  cp "$STUB_RUN/outputs/stage1/"* "$STUB_RUN/outputs/stage3/"
  echo 0 > "$STUB/state/posts"; echo '[]' > "$STUB/state/reviews.json"; echo '[]' > "$STUB/state/comments.json"; : > "$STUB/state/calls.log"
}
stub_run() {  # stub_run <command...> — runs it against the fake HOME and the stub gh, with no retry wait
  ( export HOME="$STUB/home" PATH="$STUB/bin:$PATH" STUB_STATE="$STUB/state" PR_QUORUM_API_BACKOFF="0 0"
    unset PR_QUORUM_BOT_ENV GH_HOST GH_TOKEN GITHUB_TOKEN PR_QUORUM_LOCK_PID
    "$@" )
}
stub_post() {  # stub_post [stage] — post-review of that stage's draft
  local s="${1:-stage1}"
  stub_run "$PR_QUORUM" post-review demo 1 "$STUB_SHA" "$STUB_RUN/outputs/$s/summary.md" "$STUB_RUN/outputs/$s/comments.json" "$s"
}
stub_posts() { cat "$STUB/state/posts"; }
stub_meta() { jq -r "$@" "$STUB_RUN/meta.json"; }

# T1 — posted, then the comment-id GET fails: exit 4 with nothing recorded; the rerun adopts the review instead of posting again
t1_record_failure() {
  local rc=0 out
  stub_home; touch "$STUB/state/fail-comments"
  out="$(stub_post 2>&1)" || rc=$?
  [ "$rc" = 4 ] && [ "$(stub_posts)" = 1 ] && [ "$(stub_meta '.stage1 | length')" = 0 ] \
    || { echo "first run: exit $rc, POST $(stub_posts), stage1 $(stub_meta '.stage1 | length') (want 4, 1, 0)"; echo "$out"; return 1; }
  grep -q 'rerun the same post-review command' <<<"$out" || { echo "exit 4 message does not say to rerun: $out"; return 1; }
  rm "$STUB/state/fail-comments"
  out="$(stub_post 2>&1)" || { echo "rerun failed: $out"; return 1; }
  grep -q adopted <<<"$out" || { echo "rerun did not adopt: $out"; return 1; }
  [ "$(stub_posts)" = 1 ] || { echo "rerun posted again — POST count $(stub_posts)"; return 1; }
  [ "$(stub_meta '.stage1[0].review_id')" = 111 ] && [ "$(stub_meta '.stage1[0].comments[0].id')" = 111000 ] \
    || { echo "stage1 record: $(stub_meta -c .stage1)"; return 1; }
  [ -z "$(ls "$STUB_RUN/outputs/stage1" | grep posting-)" ] || { echo "posting-*.json left behind after recording"; return 1; }
}
# T2 — the server created the review but the POST response was lost: the rerun finds it in the review list and adopts it
t2_post_response_lost() {
  local rc=0 out
  stub_home; touch "$STUB/state/fail-post"
  stub_post >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] || { echo "lost response: expected exit 4, got $rc"; return 1; }
  rm "$STUB/state/fail-post"
  out="$(stub_post 2>&1)" || { echo "rerun failed: $out"; return 1; }
  [ "$(stub_posts)" = 1 ] && [ "$(stub_meta '.stage1[0].review_id')" = 111 ] \
    || { echo "POST $(stub_posts), stage1 $(stub_meta -c '[.stage1[].review_id]') (want 1, [111])"; return 1; }
}
# T3 — the review on this SHA is already recorded: running the stage again posts a new one, as before
t3_recorded_reposts() {
  local out
  stub_home
  out="$(stub_post 2>&1 && stub_post 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_posts)" = 2 ] && [ "$(stub_meta -c '[.stage1[].review_id]')" = '[111,112]' ] \
    || { echo "POST $(stub_posts), stage1 $(stub_meta -c '[.stage1[].review_id]') (want 2, [111,112])"; return 1; }
}
# T4 — an unrecorded bot review on the same SHA carries another stage's marker: Stage 3 posts its own instead of adopting it
t4_other_stage_marker() {
  local out
  stub_home
  jq -n --arg s "$STUB_SHA" '[{id:99, user:{login:"quorum-bot"}, commit_id:$s, body:"old\n\n<!-- pr-quorum:stage2 -->"}]' > "$STUB/state/reviews.json"
  out="$(stub_post stage3 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_posts)" = 1 ] && [ "$(stub_meta '.stage3.review_id')" = 111 ] \
    || { echo "POST $(stub_posts), stage3.review_id $(stub_meta '.stage3.review_id') (want 1, 111)"; return 1; }
}
# T5 — api() retries a GET on 502 and gives up at once on 404
t5_get_retry() {
  local out rc=0
  stub_home; printf 'HTTP 502: Bad Gateway\nHTTP 502: Bad Gateway\n' > "$STUB/state/fail-pr"
  out="$(stub_run "$PR_QUORUM" sha demo 1 2>&1)" || { echo "502 twice: $out"; return 1; }
  [ "$out" = "$STUB_SHA" ] && [ "$(wc -l < "$STUB/state/calls.log" | tr -d ' ')" = 3 ] \
    || { echo "502 twice: output '$out', $(wc -l < "$STUB/state/calls.log" | tr -d ' ') gh calls (want sha, 3)"; return 1; }
  stub_home; echo 'HTTP 404: Not Found' > "$STUB/state/fail-pr"
  stub_run "$PR_QUORUM" sha demo 1 >/dev/null 2>&1 || rc=$?
  [ "$rc" = 4 ] && [ "$(wc -l < "$STUB/state/calls.log" | tr -d ' ')" = 1 ] \
    || { echo "404: exit $rc, $(wc -l < "$STUB/state/calls.log" | tr -d ' ') gh calls (want 4, 1)"; return 1; }
}
# T6 — runs/ is session-writable: a link at the posting copy's path is refused before any GET or POST (no review to adopt, so only that check stops it)
t6_posting_link_refused() {
  local rc=0
  stub_home
  echo '[{"code":"X","path":"src/a.txt","line":2,"axis":"R-A","body":"R-A (Correctness) x"}]' > "$STUB/hostile.json"
  ln -s "$STUB/hostile.json" "$STUB_RUN/outputs/stage1/posting-${STUB_SHA:0:7}.json"
  stub_post >/dev/null 2>&1 || rc=$?
  [ "$rc" != 0 ] && [ "$(stub_posts)" = 0 ] && [ "$(stub_meta '.stage1 | length')" = 0 ] \
    || { echo "exit $rc, POST $(stub_posts), stage1 $(stub_meta -c '[.stage1[].review_id]') (want nonzero, 0, [])"; return 1; }
}
# T7 — Stage 3 posted twice on one SHA: the first review is still known, so a third post posts instead of adopting it
t7_repost_keeps_known() {
  local out
  stub_home
  out="$(stub_post stage3 2>&1 && stub_post stage3 2>&1 && stub_post stage3 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_posts)" = 3 ] && ! grep -q adopted <<<"$out" \
    || { echo "POST $(stub_posts) (want 3), adopted: $(grep -c adopted <<<"$out")"; return 1; }
}
check "post T1 record failure, rerun adopts"   t1_record_failure
check "post T2 lost POST response, rerun adopts" t2_post_response_lost
check "post T3 recorded review, rerun reposts"  t3_recorded_reposts
check "post T4 other stage's marker not adopted" t4_other_stage_marker
check "api T5 GET retries 5xx, not 404"         t5_get_retry
check "post T6 link at the posting copy refused" t6_posting_link_refused
check "post T7 stage3 reposts keep earlier ids known" t7_repost_keeps_known

# C1–C3 — chain.sh on a PR whose records already reach the merge gate (Stage 1 posted, Stage 2 and 3 done, two author passes,
# the last one pushing nothing), so no session runs. A GitHub read failing at the gate must stop at blocked (exit 4) with one stop notice
stub_chain_home() {
  stub_home; mkdir -p "$STUB/repo/demo" "$STUB_RUN/outputs/author"; touch "$STUB/state/chain"
  jq --arg h "$STUB_SHA" '.stage1 = [{review_id:111}] | .stage2 = [{verdicts:{}, stage_sha:$h}] | .stage3 = {comments:[]}' \
    "$STUB_RUN/meta.json" > "$STUB/t" && mv "$STUB/t" "$STUB_RUN/meta.json"
  jq -n --arg h "$STUB_SHA" '{pushed:true, to_sha:$h, tests:{result:"pass"}, blocking_open:0}' > "$STUB_RUN/outputs/author/round-01.json"
  jq -n --arg h "$STUB_SHA" '{pushed:false, to_sha:$h, tests:{result:"pass"}, blocking_open:0}' > "$STUB_RUN/outputs/author/round-02.json"
}
stub_notices() { grep -c 'issues/1/comments' "$STUB/state/calls.log"; }
chain_stop() {  # chain_stop <reason fragment> — runs the chain, expects exit 4, blocked with that reason, one notice in total, no session
  local rc=0 out
  out="$(stub_run "$HARNESS_DIR/scripts/chain.sh" demo 1 2>&1)" || rc=$?
  [ "$rc" = 4 ] && [ "$(stub_meta '.chain.state')" = blocked ] && grep -q "$1" <<<"$(stub_meta '.chain.reason')" && [ "$(stub_notices)" = 1 ] \
    || { echo "exit $rc, state $(stub_meta '.chain.state'), reason '$(stub_meta '.chain.reason')', notices $(stub_notices) (want 4, blocked, '$1', 1)"; echo "$out"; return 1; }
  ! grep -q '^claude' "$STUB/state/calls.log" || { echo "a session was started"; return 1; }
}
# C1 — the conflict check reads the PR state, the gate's own read gets a 502
c1_gate_state_fails() { stub_chain_home; printf 'ok\nHTTP 502: Bad Gateway\n' > "$STUB/state/fail-prview"; chain_stop 'PR state'; }
# C2 — the trust check and precheck read the PR, the gate's head read gets a 404
c2_gate_head_fails() { stub_chain_home; printf 'ok\nok\nHTTP 404: Not Found\n' > "$STUB/state/fail-pr"; chain_stop 'PR head'; }
# C3 — C1 again on the same records: the same reason does not post a second notice
c3_same_stop_once() {
  c1_gate_state_fails || return 1
  printf 'ok\nHTTP 502: Bad Gateway\n' > "$STUB/state/fail-prview"; chain_stop 'PR state'
}
check "chain C1 gate PR-state read fails → blocked, one notice" c1_gate_state_fails
check "chain C2 gate head read fails → blocked, one notice"     c2_gate_head_fails
check "chain C3 same stop again posts no second notice"        c3_same_stop_once

# G1–G4 — watch.sh worktree cleanup on a temp repository with worktrees for PR 1 (MERGED), 2 (CLOSED), 3 (OPEN), 4 (lookup fails)
stub_worktrees() {
  local wt
  stub_home; rm -rf "$STUB/repo"; mkdir -p "$STUB/repo/demo"
  git -C "$STUB/repo/demo" init -q && git -C "$STUB/repo/demo" -c user.name=t -c user.email=t@t commit -q --allow-empty -m init || return 1
  for wt in pr-quorum-1-abcdef0 pr-author-2 pr-author-3 pr-author-4; do
    git -C "$STUB/repo/demo" worktree add -q --detach "$STUB/repo/demo-worktrees/$wt" || return 1
  done
}
stub_wts() { ls "$STUB/repo/demo-worktrees" | paste -sd ' ' -; }
g1_closed_removed() {
  local out; stub_worktrees || return 1
  out="$(stub_run "$HARNESS_DIR/scripts/watch.sh" --gc-only 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_wts)" = "pr-author-3 pr-author-4" ] || { echo "left: $(stub_wts) (want pr-author-3 pr-author-4)"; echo "$out"; return 1; }
  grep -q 'removed — demo pr-quorum-1-abcdef0 (MERGED PR)' <<<"$out" && grep -q 'removed — demo pr-author-2 (CLOSED PR)' <<<"$out" \
    || { echo "no removal reason in the log: $out"; return 1; }
}
g2_dirty_kept() {
  local out; stub_worktrees || return 1
  touch "$STUB/repo/demo-worktrees/pr-author-2/scratch.txt"
  out="$(stub_run "$HARNESS_DIR/scripts/watch.sh" --gc-only 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_wts)" = "pr-author-2 pr-author-3 pr-author-4" ] && grep -q 'removal failed — demo pr-author-2' <<<"$out" \
    || { echo "left: $(stub_wts) (want pr-author-2 pr-author-3 pr-author-4)"; echo "$out"; return 1; }
}
g3_chain_running_kept() {
  local out; stub_worktrees || return 1
  mkdir -p "$STUB/home/.pr-quorum/runs/demo-pr2/.chain.lock"; echo $$ > "$STUB/home/.pr-quorum/runs/demo-pr2/.chain.lock/pid"
  out="$(stub_run "$HARNESS_DIR/scripts/watch.sh" --gc-only 2>&1)" || { echo "$out"; return 1; }
  [ "$(stub_wts)" = "pr-author-2 pr-author-3 pr-author-4" ] || { echo "left: $(stub_wts) (want pr-author-2 pr-author-3 pr-author-4)"; echo "$out"; return 1; }
}
g4_stamp_skips() {
  local out; stub_worktrees || return 1
  touch "$STUB/home/.pr-quorum/.gc-stamp"
  out="$(stub_run "$HARNESS_DIR/scripts/watch.sh" --once 2>&1)" || { echo "$out"; return 1; }
  [ "$(grep -c '^pr view' "$STUB/state/calls.log")" = 0 ] && [ "$(stub_wts | wc -w | tr -d ' ')" = 4 ] \
    || { echo "cleanup ran within 30 minutes of the stamp: $(grep -c '^pr view' "$STUB/state/calls.log") state lookups, left $(stub_wts)"; return 1; }
}
check "gc G1 merged and closed removed, open and unknown kept" g1_closed_removed
check "gc G2 uncommitted changes keep the worktree"            g2_dirty_kept
check "gc G3 running chain keeps the worktree"                 g3_chain_running_kept
check "gc G4 fresh .gc-stamp skips cleanup"                    g4_stamp_skips

# D1–D4 — doctor.sh on the fake HOME: template values, repository 404 vs other errors, bare sample profiles, commands that cannot start.
# The stub gh is not logged in, so doctor always exits 2 here; only the lines matter
doctor_home() {  # doctor_home [jq filter on config.json] — stub_home, path a git repository, profiles/backend.md edited from the sample
  stub_home; rm -rf "$STUB/repo"; git init -q "$STUB/repo/demo" || return 1
  mkdir -p "$STUB/home/.pr-quorum/profiles"; { cat "$HARNESS_DIR/examples/profiles/backend.md"; echo; } > "$STUB/home/.pr-quorum/profiles/backend.md"
  [ -z "${1:-}" ] || { jq "$1" "$STUB/home/.pr-quorum/config.json" > "$STUB/t" && mv "$STUB/t" "$STUB/home/.pr-quorum/config.json"; }
}
stub_doctor() { stub_run bash "$HARNESS_DIR/scripts/doctor.sh" 2>&1 || true; }
d1_template_values() {
  local out; doctor_home || return 1
  cp "$HARNESS_DIR/templates/config.json" "$STUB/home/.pr-quorum/config.json"; out="$(stub_doctor)"
  grep -qF 'FAIL — config.json still has template values: your-github-login, your-bot-login, your-repo, /absolute/path/to/your-repo' <<<"$out" \
    && ! grep -q 'config owner = your-github-login' <<<"$out" || { echo "$out"; return 1; }
}
d2_repo_404() {
  local out; doctor_home || return 1
  out="$(stub_doctor)"
  grep -q 'FAIL — demo repository acme/demo not found' <<<"$out" && ! grep -q 'not a collaborator' <<<"$out" || { echo "404: $out"; return 1; }
  touch "$STUB/state/fail-repo"; out="$(stub_doctor)"
  grep -q 'FAIL — demo cannot reach GitHub for acme/demo: HTTP 502' <<<"$out" && ! grep -q 'not found\|not a collaborator' <<<"$out" \
    || { echo "502: $out"; return 1; }
}
d3_sample_profile() {
  local out a b; doctor_home || return 1
  out="$(stub_doctor)"; a="$(grep -c '^warn — demo profile' <<<"$out")"
  cp "$HARNESS_DIR/examples/profiles/backend.md" "$STUB/home/.pr-quorum/profiles/backend.md"; out="$(stub_doctor)"
  grep -q 'warn — demo profile backend is an unmodified copy of examples/profiles/backend.md' <<<"$out" || { echo "copy: $out"; return 1; }
  b="$(grep -c '^FAIL' <<<"$out")"
  { echo; cat "$HARNESS_DIR/examples/profiles/generic.md"; } > "$STUB/home/.pr-quorum/profiles/backend.md"; out="$(stub_doctor)"
  grep -qE 'warn — demo profile backend has [1-9][0-9]* placeholder\(s\) left' <<<"$out" || { echo "fill in: $out"; return 1; }
  [ "$a" = 0 ] && [ "$b" = "$(grep -c '^FAIL' <<<"$out")" ] || { echo "edited profile warned ($a) or FAIL count changed"; return 1; }
}
d4_commands() {
  local out
  doctor_home '.repos.demo.commands = {build: "./gradlew build", test: "npm test"}' || return 1; out="$(stub_doctor)"
  grep -q 'FAIL — demo commands.build runs ./gradlew, but .* has no gradlew' <<<"$out" \
    && grep -q 'warn — demo commands.test runs npm, but .* has no package.json' <<<"$out" || { echo "missing: $out"; return 1; }
  touch "$STUB/repo/demo/gradlew" "$STUB/repo/demo/package.json"; out="$(stub_doctor)"
  ! grep -q 'commands\.' <<<"$out" || { echo "set right: $out"; return 1; }
  doctor_home || return 1; out="$(stub_doctor)"
  ! grep -q 'commands\.' <<<"$out" || { echo "no commands: $out"; return 1; }
}
check "doctor D1 template values, one line"            d1_template_values
check "doctor D2 repository 404 is not 'not a collaborator'" d2_repo_404
check "doctor D3 sample copy and <fill in> warn"       d3_sample_profile
check "doctor D4 commands that cannot start"           d4_commands

# Build sandbox (scripts/build-sandbox.sh) — under a fake HOME, the build shell must not read a fake ~/.config/pr-quorum file or ~/.npmrc, write into
# ~/.pr-quorum, the git dir or the user's ~/.gradle, or see a token from the environment, while the worktree and its own cache root
# stay writable, and on macOS must not run osascript. No network, no gh.
# Skipped on a host without a sandbox (doctor.sh reports that as FAIL)
source "$HARNESS_DIR/scripts/build-sandbox.sh"
SB_KIND="$(sandbox_kind)"
sandbox_probe() {
  local h rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1
  mkdir -p "$h/.config/pr-quorum" "$h/.pr-quorum" "$h/.gradle/wrapper" && echo canary > "$h/.config/pr-quorum/x" && echo canary > "$h/.npmrc" && git init -q "$h/wt" || return 1
  HOME="$h" GH_TOKEN=selftest-not-a-token sandbox_run "$SB_KIND" "$h/wt" "$h/wt" '
    cat "$HOME/.config/pr-quorum/x" && exit 11
    : > "$HOME/.pr-quorum/x" && exit 12
    : > .git/hooks/x && exit 13
    [ -z "${GH_TOKEN:-}" ] || exit 14
    : > "$HOME/.gradle/wrapper/x" && exit 15
    : > "$GRADLE_USER_HOME/x" || exit 16
    cat "$HOME/.npmrc" && exit 17
    [ "$(uname -s)" = Darwin ] && /usr/bin/osascript -e 1 && exit 18
    : > ok' >/dev/null 2>&1 || rc=$?
  [ "$rc" = 0 ] && [ -f "$h/wt/ok" ] || rc="${rc/#0/no-write}"
  rm -rf "$h"
  [ "$rc" = 0 ] || { echo "build shell got through (11 read secret · 12 wrote ~/.pr-quorum · 13 wrote .git · 14 saw GH_TOKEN · 15 wrote ~/.gradle · 16 cache root not writable · 17 read ~/.npmrc · 18 ran osascript): $rc"; return 1; }
}
# The shared cache root's Gradle init files — a file planted there by one build is cleared before the next run, a hard link is unlinked
# without touching its target, and a symlink is refused
sandbox_gradle_reset() {
  local h c rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1; c="$h/.cache/pr-quorum-build/gradle"
  mkdir -p "$c/init.d" "$h/wt" "$h/.config/pr-quorum" && echo planted > "$c/init.d/x.gradle" && echo planted > "$c/init.gradle" && git init -q "$h/wt" || return 1
  HOME="$h" sandbox_run "$SB_KIND" "$h/wt" "$h/wt" '[ -z "$(ls "$GRADLE_USER_HOME/init.d")" ] && [ ! -s "$GRADLE_USER_HOME/init.gradle" ]' \
    >/dev/null 2>&1 || rc=1
  [ "$rc" = 0 ] && [ ! -e "$c/init.d/x.gradle" ] && [ ! -e "$c/init.gradle" ] || { echo "planted init files survived"; rc=1; }
  # A hard link at gradle.properties must be unlinked, not truncated through
  echo keep > "$h/victim" && rm -f "$c/gradle.properties" && ln "$h/victim" "$c/gradle.properties" || return 1
  HOME="$h" sandbox_run "$SB_KIND" "$h/wt" "$h/wt" true >/dev/null 2>&1
  [ "$(cat "$h/victim")" = keep ] || { echo "the host reset truncated a hard-linked gradle.properties target"; rc=1; }
  ln -sf "$h/elsewhere" "$c/gradle.properties"
  HOME="$h" sandbox_run "$SB_KIND" "$h/wt" "$h/wt" true >/dev/null 2>&1 && { echo "linked gradle.properties was not refused"; rc=1; }
  rm -rf "$h"
  return "$rc"
}
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) resets the shared Gradle init files" sandbox_gradle_reset; fi
# A secret entry that is a link (a dotfile manager's ~/.npmrc -> ~/dotfiles/npmrc) — its target outside HOME must stay unreadable too
sandbox_linked_secret() {
  local h rc=0
  h="$(cd "$(mktemp -d)" && pwd -P)" || return 1
  mkdir -p "$h/home/.config/pr-quorum" "$h/dotfiles" "$h/home/wt" && echo canary > "$h/dotfiles/npmrc" && ln -s "$h/dotfiles/npmrc" "$h/home/.npmrc" \
    && git init -q "$h/home/wt" || return 1
  HOME="$h/home" sandbox_run "$SB_KIND" "$h/home/wt" "$h/home/wt" "cat '$h/dotfiles/npmrc' || cat \"\$HOME/.npmrc\"" >/dev/null 2>&1 \
    && { echo "the target of a linked ~/.npmrc was readable"; rc=1; }
  rm -rf "$h"
  return "$rc"
}
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) refuses the target of a linked secret" sandbox_linked_secret; fi
if [ -n "$SB_KIND" ]; then check "build sandbox ($SB_KIND) blocks secrets, harness state, .git, user caches and env tokens" sandbox_probe
else echo "warning — no build sandbox on this host (sandbox-exec / bwrap) — skipping its check"; fi

[ -d "$RUNS" ] || { echo "no runs/ — skipping PG5/PG6"; echo "selftest — passed $pass · failed $fail"; [ "$fail" = 0 ] || exit 3; exit 0; }

# PG5 — folders with both a summary and comments. The stage comes from the path (in early runs, outputs/ itself is Stage 1).
while IFS= read -r d; do
  case "$d" in */stage2*) st=stage2 ;; */stage3*) st=stage3 ;; *) st=stage1 ;; esac
  [ -f "$d/comments.json" ] && check "pg5 ${d#"$RUNS"/} ($st)" "$PR_QUORUM" pg5 "$d/summary.md" "$d/comments.json" "$st"
done < <(find "$RUNS"/*/outputs -name summary.md -not -path '*/pre-polish/*' -exec dirname {} \; | sort)

# PG6 — folders with a pre-edit copy
while IFS= read -r p; do
  d="$(dirname "$p")"
  # A copy directly under outputs/ is the layout from before per-stage folders (L0-15). The original moved to stage1/, so there is nothing to compare against
  [ "$(basename "$d")" = outputs ] && { echo "skipped — ${d#"$RUNS"/}/pre-polish (layout from before per-stage folders)"; continue; }
  check "pg6 ${d#"$RUNS"/}" "$PR_QUORUM" pg6 "$d"
done < <(find "$RUNS"/*/outputs -type d -name pre-polish | sort)

echo "selftest — passed $pass · failed $fail"
[ "$fail" = 0 ] || exit 3
