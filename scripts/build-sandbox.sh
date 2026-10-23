# build-sandbox.sh — runs one build command with an emptied environment.
# Sourced by pr-quorum.sh (cmd_build). The build reads files the PR controls (build.gradle, package.json scripts),
# so whatever runs here is treated as untrusted: no credentials from the environment, and gh and git find no stored login.
# Docs: docs/harness.md §3 (build).

# Variables the build shell keeps when they are set. build.env_passthrough in config.json adds names (sandbox_env_ok decides which)
SANDBOX_ENV_KEEP="PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM JAVA_HOME GRADLE_USER_HOME NVM_DIR"

# sandbox_env_ok <name> — a passthrough name must look like a variable name and must not look like a credential
sandbox_env_ok() {
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
  case "$1" in *TOKEN*|*SECRET*|*KEY*|PR_QUORUM_*) return 1 ;; esac
}

# sandbox_run <env> <worktree root> <dir> <command> [passthrough names...]
# Runs bash -c <command> in <dir>. The exit code is the command's own
sandbox_run() {
  local mode="$1" wt="$2" dir="$3" cmd="$4" n no ghdir rc=0
  shift 4
  no=/usr/bin/false; [ -x "$no" ] || no=/bin/false
  ghdir="$(mktemp -d)"   # gh finds no login in an empty config folder

  # env -i drops everything else: GH_TOKEN, ANTHROPIC_API_KEY, SSH_AUTH_SOCK, PR_QUORUM_*. The fixed values come last so they win.
  # The Gradle daemon is off because a build would otherwise run in an already running daemon (plan 2-01 step 0)
  local envs=(env -i)
  for n in $SANDBOX_ENV_KEEP "$@"; do
    [ -n "${!n+x}" ] && envs+=("$n=${!n}")
  done
  envs+=("GH_CONFIG_DIR=$ghdir" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
         "GIT_ASKPASS=$no" "SSH_ASKPASS=$no" GRADLE_OPTS=-Dorg.gradle.daemon=false)

  case "$mode" in
    env) (cd "$dir" && exec "${envs[@]}" bash -c "$cmd") || rc=$? ;;
    *) rc=2 ;;
  esac
  rm -rf "$ghdir"
  return "$rc"
}
