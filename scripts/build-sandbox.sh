# shellcheck shell=bash
# build-sandbox.sh — runs one build command with an emptied environment inside an OS sandbox (Seatbelt on macOS, bubblewrap on Linux).
# Sourced by pr-quorum.sh (cmd_build), doctor.sh and selftest.sh. The build reads files the PR controls (build.gradle, package.json scripts),
# so whatever runs here is treated as untrusted: no credentials, no harness state, no writes outside the worktree, temp and its own cache root.
# Docs: docs/harness.md §3 (build). Network stays open — dependency registries need it (improvement plan 2-01 §5).

# Variables the build shell keeps when they are set. build.env_passthrough in config.json adds names (sandbox_env_ok decides which)
SANDBOX_ENV_KEEP="PATH HOME USER LOGNAME SHELL TMPDIR LANG LC_ALL LC_CTYPE TERM JAVA_HOME NVM_DIR"

# Paths under HOME a build may neither read nor write, one per line: credentials (gh, git, registries, cloud, SSH, keychain, browser data),
# harness state, and shell history. A build that needs private-registry auth from one of these files needs build.sandbox "off"
SANDBOX_SECRETS='.config
.ssh
.aws
.gnupg
.netrc
.docker
.kube
.claude
.claude.json
.pr-quorum
.git-credentials
.npmrc
.yarnrc
.yarnrc.yml
.m2/settings.xml
.m2/settings-security.xml
.pypirc
.cargo/credentials
.cargo/credentials.toml
.gradle/gradle.properties
.zsh_history
.bash_history
Library/Keychains
Library/Application Support
Library/Cookies'

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

# Seatbelt profile. __SECRETS__ becomes SANDBOX_SECRETS. Later rules win, so each deny comes after the allow it narrows. The secret paths and the user's own caches are refused
# for writes too, in case one of them sits under an allowed folder (a HOME under /tmp, as in selftest.sh).
# Builds get their own cache root (CACHE): what they leave in a cache is run again by later builds, so the user's ~/.gradle, ~/.m2, ~/.npm,
# ~/.cache and ~/Library/Caches stay read-only — a poisoned wrapper, JDK or package would otherwise run in the user's own builds.
# The git dir stays read-only: hooks or a rewritten .git pointer would run in the next git commit, outside the sandbox.
# (allow default) leaves other mach services open (the JVM needs some); Apple events, LaunchServices and the tools that drive them or
# launchd and the keychain are refused, so a build cannot hand work to a process outside the sandbox that way. A copied binary still meets
# the appleevent-send, lsopen and SecurityServer denies
SANDBOX_SEATBELT='(version 1)
(allow default)
(define (home p) (subpath (string-append (param "HOME") p)))
(define (cache p) (subpath (string-append (param "CACHE") p)))
(define secrets (require-any __SECRETS__ (subpath (param "BOT"))))
(deny file-write*)
(allow file-write* (subpath (param "WT")) (subpath (param "TMP")) (subpath "/private/tmp") (subpath "/private/var/tmp") (subpath "/dev"))
(deny file-write* secrets (subpath (string-append (param "WT") "/.git")) (subpath (param "GITDIR"))
  (home "/.gradle") (home "/.m2") (home "/.npm") (home "/.cache") (home "/Library/Caches"))
(allow file-write* (subpath (param "CACHE")))
(deny file-write* (cache "/gradle/init.d") (cache "/gradle/gradle.properties") (cache "/gradle/init.gradle") (cache "/gradle/init.gradle.kts"))
(deny file-read* secrets)
(deny mach-lookup (global-name "com.apple.SecurityServer"))
(deny appleevent-send)
(deny lsopen)
(deny process-exec (literal "/usr/bin/open") (literal "/usr/bin/osascript") (literal "/bin/launchctl") (literal "/usr/bin/security"))
(deny network-outbound (remote unix-socket (path-regex #"^/private/var/run/com\.apple\.launchd\.[^/]+/Listeners$")))'

# sandbox_canon <path> — the path with its parent folder resolved (pwd -P), as the sandbox matches real paths. Fails if the parent is missing
sandbox_canon() {
  local d; d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || return 1
  echo "$d/$(basename "$1")"
}

# sandbox_realpath <path> — follows links on the last component (readlink loop, at most 20), then resolves the parent. BSD and GNU alike
sandbox_realpath() {
  local p="$1" l n=0
  while [ -L "$p" ]; do
    n=$((n+1)); [ "$n" -le 20 ] && l="$(readlink "$p")" || return 1
    case "$l" in /*) p="$l" ;; *) p="$(dirname "$p")/$l" ;; esac
  done
  sandbox_canon "$p"
}

# sandbox_run <seatbelt|bwrap|off> <worktree root> <dir> <command> [passthrough names...]
# Runs bash -c <command> in <dir>. The exit code is the command's own. off runs it as before this file existed — inherited environment, no sandbox.
# BOT_ENV, when set, is hidden too (its location can be moved with PR_QUORUM_BOT_ENV)
sandbox_run() {
  local mode="$1" wt="$2" dir="$3" cmd="$4" n p t home tmp cache bot gitdir no ghdir mvn sec="" rc=0
  shift 4
  [ "$mode" = off ] && { (cd "$dir" && exec bash -c "$cmd"); return; }
  home="$(cd "$HOME" && pwd -P)"
  tmp="$(cd "${TMPDIR:-/tmp}" && pwd -P)"
  # Resolved before ghdir exists, so a failure leaves nothing behind. Unresolvable means the rules would not match: fail closed
  cache="$home/.cache/pr-quorum-build"
  [ ! -L "$cache" ] && mkdir -p "$cache/gradle" "$cache/npm" "$cache/m2" "$cache/xdg" && cache="$(sandbox_canon "$cache")" \
    || { echo "build-sandbox: cannot resolve the cache root $cache, or it is a link" >&2; return 2; }
  # The cache root is shared by every PR's build, and Gradle runs init scripts and gradle.properties from it on every build — a file one
  # build planted there would run in the next PR's build and could falsify its test results. Reset them on the host before every run,
  # and refuse when one is a link (a read-only bind or deny rule of a swapped link protects the target, not the path Gradle reads)
  for p in "$cache/gradle" "$cache/gradle/init.d" "$cache/gradle/gradle.properties" "$cache/gradle/init.gradle" "$cache/gradle/init.gradle.kts"; do
    [ ! -L "$p" ] || { echo "build-sandbox: $p is a link — a build may have planted it; remove it by hand" >&2; return 2; }
  done
  # Unlink before creating: truncating in place would empty whatever a planted hard link points at (a user's ~/.zshrc)
  rm -rf "$cache/gradle/init.d" && mkdir "$cache/gradle/init.d" \
    && rm -f "$cache/gradle/gradle.properties" "$cache/gradle/init.gradle" "$cache/gradle/init.gradle.kts" \
    && : > "$cache/gradle/gradle.properties" \
    || { echo "build-sandbox: cannot reset the Gradle init files under $cache/gradle" >&2; return 2; }
  # A missing folder holds no token to hide, so the path is refused as written rather than failing the build
  bot="${BOT_ENV:-$home/.config/pr-quorum/bot.env}"; bot="$(sandbox_canon "$bot")" || bot="${BOT_ENV:-$home/.config/pr-quorum/bot.env}"
  # Secret entries that exist, resolved: a dotfile manager's ~/.npmrc -> ~/dotfiles/npmrc would otherwise slip past a rule on the link path,
  # as Seatbelt matches real paths. "d <path>" or "f <path>", for both the link and its target. Unresolvable or unquotable: fail closed
  local hide=""
  while IFS= read -r p; do
    [ -e "$home/$p" ] || [ -L "$home/$p" ] || continue
    t="$(sandbox_realpath "$home/$p")" && [[ "$t" != *[\"\\]* ]] \
      || { echo "build-sandbox: cannot resolve $home/$p to a usable path" >&2; return 2; }
    [ "$t" = "$home/$p" ] && continue
    if [ -d "$t" ]; then hide="$hide"$'\n'"d $t"; else hide="$hide"$'\n'"f $t"; fi
  done <<<"$SANDBOX_SECRETS"
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
      while IFS= read -r p; do sec="$sec (home \"/$p\")"; done <<<"$SANDBOX_SECRETS"
      while IFS= read -r p; do
        case "$p" in "d "*) sec="$sec (subpath \"${p#d }\")" ;; "f "*) sec="$sec (literal \"${p#f }\")" ;; esac
      done <<<"$hide"
      (cd "$dir" && exec sandbox-exec -D "WT=$wt" -D "HOME=$home" -D "TMP=$tmp" -D "CACHE=$cache" -D "BOT=$bot" -D "GITDIR=$gitdir" \
        -p "${SANDBOX_SEATBELT/__SECRETS__/$sec}" "${envs[@]}" bash -c "$cmd") || rc=$? ;;
    bwrap)
      # / is read-only, so only the writable places need naming. Credential paths are covered by an empty tmpfs (folder) or /dev/null (file)
      local args=(--ro-bind / / --dev /dev --proc /proc --tmpfs /tmp)
      [ "$tmp" = /tmp ] || args+=(--bind "$tmp" "$tmp")
      args+=(--bind "$wt" "$wt")
      [ -e "$wt/.git" ] && args+=(--ro-bind "$wt/.git" "$wt/.git")
      [ -d "$gitdir" ] && args+=(--ro-bind "$gitdir" "$gitdir")
      args+=(--bind "$cache" "$cache")
      # Gradle's init files in the shared cache: empty and not writable, so one build cannot plant code for the next
      args+=(--tmpfs "$cache/gradle/init.d")
      for p in gradle.properties init.gradle init.gradle.kts; do args+=(--ro-bind /dev/null "$cache/gradle/$p"); done
      while IFS= read -r p; do
        if [ -d "$home/$p" ]; then args+=(--tmpfs "$home/$p"); elif [ -e "$home/$p" ]; then args+=(--ro-bind /dev/null "$home/$p"); fi
      done <<<"$SANDBOX_SECRETS"
      while IFS= read -r p; do
        case "$p" in "d "*) args+=(--tmpfs "${p#d }") ;; "f "*) args+=(--ro-bind /dev/null "${p#f }") ;; esac
      done <<<"$hide"
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
