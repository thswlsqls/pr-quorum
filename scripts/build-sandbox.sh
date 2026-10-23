# build-sandbox.sh — runs one build command with an emptied environment inside an OS sandbox (Seatbelt on macOS, bubblewrap on Linux).
# Sourced by pr-quorum.sh (cmd_build), doctor.sh and selftest.sh. The build reads files the PR controls (build.gradle, package.json scripts),
# so whatever runs here is treated as untrusted: no credentials, no harness state, no writes outside the worktree, temp and its own cache root.
# Docs: docs/harness.md §3 (build). Network stays open — dependency registries need it (improvement plan 2-01 §5).

# Variables the build shell keeps when they are set. build.env_passthrough in config.json adds names (sandbox_env_ok decides which)
SANDBOX_ENV_KEEP="PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM JAVA_HOME NVM_DIR"

# sandbox_kind — prints seatbelt or bwrap for this host, or nothing when the tool is not installed
sandbox_kind() {
  case "$(uname -s)" in
    Darwin) command -v sandbox-exec >/dev/null && echo seatbelt ;;
    Linux)  command -v bwrap >/dev/null && echo bwrap ;;
  esac
  return 0
}

# sandbox_env_ok <name> — a passthrough name must look like a variable name and must not look like a credential
sandbox_env_ok() {
  [[ "$1" =~ ^[A-Z_][A-Z0-9_]*$ ]] || return 1
  case "$1" in *TOKEN*|*SECRET*|*KEY*|PR_QUORUM_*) return 1 ;; esac
}

# Seatbelt profile. Later rules win, so each deny comes after the allow it narrows. The secret paths and the user's own caches are refused
# for writes too, in case one of them sits under an allowed folder (a HOME under /tmp, as in selftest.sh).
# Builds get their own cache root (CACHE): what they leave in a cache is run again by later builds, so the user's ~/.gradle, ~/.m2, ~/.npm,
# ~/.cache and ~/Library/Caches stay read-only — a poisoned wrapper, JDK or package would otherwise run in the user's own builds.
# The git dir stays read-only: hooks or a rewritten .git pointer would run in the next git commit, outside the sandbox
SANDBOX_SEATBELT='(version 1)
(allow default)
(define (home p) (subpath (string-append (param "HOME") p)))
(define (cache p) (subpath (string-append (param "CACHE") p)))
(define secrets (require-any (home "/.config") (home "/.ssh") (home "/.aws") (home "/.gnupg") (home "/.netrc") (home "/.docker")
  (home "/.kube") (home "/.claude") (home "/.claude.json") (home "/.pr-quorum") (home "/Library/Keychains") (subpath (param "BOT"))))
(deny file-write*)
(allow file-write* (subpath (param "WT")) (subpath (param "TMP")) (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath "/dev"))
(deny file-write* secrets (subpath (string-append (param "WT") "/.git")) (subpath (param "GITDIR"))
  (home "/.gradle") (home "/.m2") (home "/.npm") (home "/.cache") (home "/Library/Caches"))
(allow file-write* (subpath (param "CACHE")))
(deny file-write* (cache "/gradle/init.d") (cache "/gradle/gradle.properties"))
(deny file-read* secrets)
(deny mach-lookup (global-name "com.apple.SecurityServer"))
(deny network-outbound (remote unix-socket (path-regex #"^/private/var/run/com\.apple\.launchd\.[^/]+/Listeners$")))'

# sandbox_run <seatbelt|bwrap|off> <worktree root> <dir> <command> [passthrough names...]
# Runs bash -c <command> in <dir>. The exit code is the command's own. off runs it as before this file existed — inherited environment, no sandbox.
# BOT_ENV, when set, is hidden too (its location can be moved with PR_QUORUM_BOT_ENV)
sandbox_run() {
  local mode="$1" wt="$2" dir="$3" cmd="$4" n home tmp cache bot gitdir no ghdir mvn rc=0
  shift 4
  [ "$mode" = off ] && { (cd "$dir" && exec bash -c "$cmd"); return; }
  home="$(cd "$HOME" && pwd -P)"
  tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  cache="$home/.cache/pr-quorum-build"
  mkdir -p "$cache/gradle" "$cache/npm" "$cache/m2" "$cache/xdg" || return 2   # before ghdir, so nothing is left behind
  bot="${BOT_ENV:-$home/.config/pr-quorum/bot.env}"
  gitdir="$(cd "$wt" && cd "$(git rev-parse --git-common-dir 2>/dev/null || echo .git)" 2>/dev/null && pwd -P)" || gitdir="$wt/.git"
  no=/usr/bin/false; [ -x "$no" ] || no=/bin/false
  ghdir="$(mktemp -d)"   # gh finds no login in an empty config folder

  # env -i drops everything else: GH_TOKEN, ANTHROPIC_API_KEY, SSH_AUTH_SOCK, PR_QUORUM_*. The fixed values come last so they win.
  # The Gradle daemon is off because a build would otherwise run in an already running daemon, outside this sandbox (plan 2-01 step 0);
  # its own GRADLE_USER_HOME also keeps it away from the user's daemon registry. MAVEN_OPTS is appended to only when passed through
  local envs=(env -i)
  mvn="-Dmaven.repo.local=$cache/m2"
  for n in $SANDBOX_ENV_KEEP "$@"; do
    [ "$n" = MAVEN_OPTS ] && [ -n "${MAVEN_OPTS:-}" ] && { mvn="$MAVEN_OPTS $mvn"; continue; }
    [ -n "${!n+x}" ] && envs+=("$n=${!n}")
  done
  envs+=("GH_CONFIG_DIR=$ghdir" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null GIT_TERMINAL_PROMPT=0
         "GIT_ASKPASS=$no" "SSH_ASKPASS=$no" GRADLE_OPTS=-Dorg.gradle.daemon=false
         "GRADLE_USER_HOME=$cache/gradle" "npm_config_cache=$cache/npm" "MAVEN_OPTS=$mvn" "XDG_CACHE_HOME=$cache/xdg")

  case "$mode" in
    seatbelt)
      (cd "$dir" && exec sandbox-exec -D "WT=$wt" -D "HOME=$home" -D "TMP=$tmp" -D "CACHE=$cache" -D "BOT=$bot" -D "GITDIR=$gitdir" \
        -p "$SANDBOX_SEATBELT" "${envs[@]}" bash -c "$cmd") || rc=$? ;;
    bwrap)
      # / is read-only, so only the writable places need naming. Credential paths are covered by an empty tmpfs (folder) or /dev/null (file)
      local args=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp) p
      [ "$tmp" = /tmp ] || args+=(--bind "$tmp" "$tmp")
      args+=(--bind "$wt" "$wt")
      [ -e "$wt/.git" ] && args+=(--ro-bind "$wt/.git" "$wt/.git")
      [ -d "$gitdir" ] && args+=(--ro-bind "$gitdir" "$gitdir")
      args+=(--bind "$cache" "$cache")
      # Gradle runs these on every build — kept empty and read-only so one build cannot plant code for the next
      mkdir -p "$cache/gradle/init.d" && : >> "$cache/gradle/gradle.properties" || { rm -rf "$ghdir"; return 2; }
      args+=(--ro-bind "$cache/gradle/init.d" "$cache/gradle/init.d" --ro-bind "$cache/gradle/gradle.properties" "$cache/gradle/gradle.properties")
      for p in .config .ssh .aws .gnupg .netrc .docker .kube .claude .claude.json .pr-quorum; do
        if [ -d "$home/$p" ]; then args+=(--tmpfs "$home/$p"); elif [ -e "$home/$p" ]; then args+=(--ro-bind /dev/null "$home/$p"); fi
      done
      [ -f "$bot" ] && args+=(--ro-bind /dev/null "$bot")
      [ -d "/run/user/$(id -u)" ] && args+=(--tmpfs "/run/user/$(id -u)")   # session D-Bus (keyring) lives here
      args+=(--unshare-all --share-net --die-with-parent --new-session --chdir "$dir")
      bwrap "${args[@]}" "${envs[@]}" bash -c "$cmd" || rc=$? ;;
    *) rc=2 ;;
  esac
  rm -rf "$ghdir"
  return "$rc"
}

# sandbox_check <seatbelt|bwrap> — runs true inside the sandbox once. Fails when the sandbox cannot start
# (on Ubuntu 24.04+ AppArmor may block the unprivileged user namespaces bwrap needs)
sandbox_check() {
  local d rc=0; d="$(cd "$(mktemp -d)" && pwd -P)"
  sandbox_run "$1" "$d" "$d" true >/dev/null 2>&1 || rc=$?
  rm -rf "$d"
  return "$rc"
}
