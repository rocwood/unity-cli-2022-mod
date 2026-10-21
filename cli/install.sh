#!/usr/bin/env bash
# Unity CLI Installer
# https://unity.com
#
# Usage:
#   curl -fsSL https://unity.com/install.sh | bash
#
# Environment variables:
#   UNITY_CLI_HOME    - Installation directory. When set, installs the
#                       <UNITY_CLI_HOME>/bin/unity layout with env files.
#                       Default: bare binary in ~/.local/bin on Linux (the
#                       XDG-conventional user bin dir), ~/.unity on macOS.
#   UNITY_CLI_VERSION - Version to install (default: latest from manifest)
#   UNITY_CLI_CHANNEL - Release channel: alpha, beta, or empty for stable.
#                       When empty and no stable release has shipped yet,
#                       falls back to beta automatically.

set -euo pipefail

# ─── Colors ───────────────────────────────────────────────────────────────────
# Defined before any use: the channel validation below references $RED/$NC, and
# `set -u` aborts the script on an unbound variable. Only a terminal gets escape
# codes: a piped or captured install (an agent running the one-liner) reads
# plain text, and NO_COLOR opts out everywhere.
if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then
  RED='\033[0;31m'
  GREEN='\033[0;32m'
  YELLOW='\033[1;33m'
  BLUE='\033[0;34m'
  BOLD='\033[1m'
  NC='\033[0m'
else
  RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

info()  { echo -e "  ${BLUE}info${NC}  $1"; }
warn()  { echo -e "  ${YELLOW}warn${NC}  $1" >&2; }
error() { echo -e "\n  ${RED}error${NC} $1\n" >&2; exit 1; }

CDN_BASE="${UNITY_CLI_CDN_BASE:-https://public-cdn.cloud.unity3d.com/hub/prod/cli/}"
INSTALL_DIR="${UNITY_CLI_HOME:-$HOME/.unity}"

# Install layout:
#   xdg  — bare binary in ~/.local/bin (Linux default). The XDG-conventional
#          user bin dir is on PATH out of the box on most distros, so no env
#          files and usually no shell-config edits are needed.
#   home — <INSTALL_DIR>/bin/unity plus env files sourced from shell configs
#          (macOS default, and any platform when UNITY_CLI_HOME is set).
if [ -n "${UNITY_CLI_HOME:-}" ]; then
  LAYOUT="home"
elif [ "$(uname -s)" = "Linux" ]; then
  LAYOUT="xdg"
else
  LAYOUT="home"
fi

if [ "$LAYOUT" = "xdg" ]; then
  BIN_DIR="$HOME/.local/bin"
else
  BIN_DIR="$INSTALL_DIR/bin"
fi

# Channel selects the version manifest: latest.json, latest-beta.json, latest-alpha.json
CHANNEL=$(printf '%s' "${UNITY_CLI_CHANNEL:-}" | tr '[:upper:]' '[:lower:]')
case "$CHANNEL" in
  "")    MANIFEST_FILE="latest.json" ;;
  alpha) MANIFEST_FILE="latest-alpha.json" ;;
  beta)  MANIFEST_FILE="latest-beta.json" ;;
  *)     error "Invalid UNITY_CLI_CHANNEL: '$CHANNEL'. Allowed: alpha, beta, or empty for stable." ;;
esac

# Use $HOME-relative path for portability in shell config files
if [[ "$BIN_DIR" == "$HOME/"* ]]; then
  BIN_DIR_REF="\$HOME${BIN_DIR#"$HOME"}"
else
  BIN_DIR_REF="$BIN_DIR"
fi

# ─── Requirements ─────────────────────────────────────────────────────────────
check_requirements() {
  if ! command -v curl &>/dev/null && ! command -v wget &>/dev/null; then
    error "curl or wget is required to install Unity CLI."
  fi
}

# ─── Platform detection ───────────────────────────────────────────────────────
detect_platform() {
  local os arch
  os="$(uname -s)"
  arch="$(uname -m)"

  case "$os" in
    Darwin) os="darwin" ;;
    Linux)  os="linux" ;;
    MINGW*|MSYS*|CYGWIN*)
      error "Windows detected. Use the PowerShell installer instead:\n\n    irm ${CDN_BASE}install.ps1 | iex"
      ;;
    *) error "Unsupported operating system: $os" ;;
  esac

  case "$arch" in
    x86_64|amd64) arch="x64" ;;
    arm64|aarch64) arch="arm64" ;;
    *) error "Unsupported architecture: $arch" ;;
  esac

  echo "${os}-${arch}"
}

# Minimum glibc for the Linux binaries (CLI-587). The C# Native AOT build needs
# GLIBC_2.34 — it covers __libc_start_main, so the loader fails BEFORE main and
# the binary cannot even print its own error. Without this preflight the
# installer reports success and leaves an executable that only ever says
# "version `GLIBC_2.34' not found".
#
# Keep in step with apps/cli/packaging/nfpm.yaml (the deb/rpm floor) and
# scripts/checks/assert-glibc-floor.mts (the build-time drift guard).
GLIBC_MIN="2.34"

# Refuse only on POSITIVE evidence of an unsupported libc. A host whose glibc
# version cannot be determined is left alone: a false refusal here blocks an
# install that would have worked, which is worse than the loader error we are
# trying to pre-empt. musl is refused outright — these binaries are glibc-only
# (the npm children declare `libc: ["glibc"]` for the same reason).
check_glibc() {
  local reported=""

  # `|| true` on both probes is load-bearing under `set -euo pipefail`. A probe
  # that exits non-zero — musl and busybox `getconf` reject GNU_LIBC_VERSION,
  # and musl's `ldd` exits non-zero by design — propagates into the assignment's
  # status, and `set -e` kills the script from the `case` that calls this (a
  # `case` body is not a tested context, so `set -e` is live there), exiting
  # with the probe's own code before ANY of the messages below can print. That
  # silent abort refused supported hosts and made the musl branch unreachable,
  # inverting the fail-open intent stated above.
  if command -v getconf >/dev/null 2>&1; then
    reported="$(getconf GNU_LIBC_VERSION 2>/dev/null | awk '{ print $2 }')" || true
  fi
  if [ -z "$reported" ] && command -v ldd >/dev/null 2>&1; then
    # Capture ONCE, then match in-shell. A pipeline here reintroduces the same
    # `pipefail` trap from the other direction: `head -n1`/`grep -q` exit as soon
    # as they have what they need, SIGPIPE `ldd` to 141, and the pipeline reports
    # 141 even when `grep` DID match — so the musl refusal below would be skipped
    # and an unsupported host allowed through. Reproduced with an `ldd` whose
    # output overflows the pipe buffer. A here-string has no producer process to
    # signal, and `${x##* }` replaces `awk '{ print $NF }'` with no subshell.
    local ldd_out=""
    ldd_out="$(ldd --version 2>&1)" || true
    ldd_out="${ldd_out%%$'\n'*}"
    if grep -qi musl <<<"$ldd_out"; then
      error "This system uses musl libc. The Unity CLI requires glibc ${GLIBC_MIN} or newer.\n  Alpine and other musl distributions are not supported."
    fi
    reported="${ldd_out##* }"
  fi

  case "$reported" in
    ''|*[!0-9.]*) return 0 ;;  # undeterminable or not a bare version — do not block
  esac

  # Numeric major/minor compare; `sort -V` is not in every minimal image.
  if awk -v have="$reported" -v need="$GLIBC_MIN" '
      BEGIN {
        split(have, h, "."); split(need, n, ".");
        exit !((h[1] + 0) < (n[1] + 0) || ((h[1] + 0) == (n[1] + 0) && (h[2] + 0) < (n[2] + 0)));
      }'; then
    error "This system has glibc ${reported}; the Unity CLI requires ${GLIBC_MIN} or newer.\n  Affected: Ubuntu 20.04 and older, Debian 11, RHEL/CentOS 8, Amazon Linux 2.\n  Nothing was installed or changed."
  fi
}

# ─── HTTP helpers ─────────────────────────────────────────────────────────────
http_get() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url"
  else
    wget -qO- "$url"
  fi
}

http_download() {
  local url="$1" dest="$2"
  if command -v curl &>/dev/null; then
    curl -fsSL "$url" -o "$dest"
  else
    wget -qO "$dest" "$url"
  fi
}

# Returns the HTTP status code for $1, or empty when it cannot be determined
# (e.g. a wget without --server-response support). Used only to decide
# whether the DEFAULT channel's manifest fetch failed with a 404 specifically
# -- see the beta fallback in main() -- never to gate behavior on an
# explicitly-requested channel.
http_status() {
  local url="$1"
  if command -v curl &>/dev/null; then
    curl -s -o /dev/null -w '%{http_code}' "$url" 2>/dev/null
  else
    wget --server-response -q -O /dev/null "$url" 2>&1 | awk '/^  HTTP\// { print $2 }' | tail -1
  fi
}

# ─── Manifest parsing ─────────────────────────────────────────────────────────
# Read a string field out of the manifest, without jq.
#
# A regex cannot match balanced braces, so the `"<key>":{[^}]*}` section grep this
# replaced stopped at the closing brace of the NESTED `brotli` object that
# build-cli-binaries.yml adds to every compressed platform entry. The captured
# section then held two "filename"/"sha256" pairs, `grep -o` emitted both, and the
# newline between them went straight into the download URL, which curl rejects as
# malformed (CLI-1292). Every platform except the two *-appimage keys was affected.
#
# `path` is a /-separated key path to the CONTAINING object ("" = the document
# root), so this resolves the same location the jq branch does —
# `.binaries["<platform>"]`, not the first `"<platform>":{` anywhere in the file.
# Scoping matters: the manifest already carries `packageManagers` as a top-level
# map-of-objects beside `binaries`, so an unscoped search is one added platform-
# keyed sibling away from silently reading the wrong object. Platform keys never
# contain "/", so the separator is unambiguous.
#
# The scan tracks brace depth and steps over string literals whole, so a brace or
# an escaped quote inside a value cannot desync it, and only matches a string
# followed by ":" at depth 1 — a key, never a value that equals the key name.
#
# Returns the value's RAW bytes: JSON escapes are passed through, not decoded.
# The three fields read here (version, filename, sha256) cannot contain one.
#
# awk is already required by check_glibc, verify_sha256 and the wget branch of
# http_status, so this adds no new dependency. POSIX awk only — no gawk builtins.
json_string_field() {
  printf '%s' "$1" | awk -v path="$2" -v field="$3" '
  # index of the closing quote of the string literal opening at i
  function str_end(s, i,   j, d) {
    j = i + 1
    while (j <= length(s)) {
      d = substr(s, j, 1)
      if (d == "\\") { j += 2; continue }
      if (d == "\"") return j
      j++
    }
    return 0
  }
  # contents of the string literal opening at i, escapes left as written
  function str_at(s, i,   j, out, d) {
    j = i + 1; out = ""
    while (j <= length(s)) {
      d = substr(s, j, 1)
      if (d == "\\") { out = out substr(s, j, 2); j += 2; continue }
      if (d == "\"") break
      out = out d; j++
    }
    return out
  }
  # find KEY at depth 1 of the object whose body starts at i; return the index
  # just past its closing quote, or 0. A string counts as a key only when it is
  # followed by ":", so a VALUE equal to the key name can never match.
  function find_key(s, i, key,   n, depth, c, j) {
    n = length(s); depth = 1
    while (i <= n && depth > 0) {
      c = substr(s, i, 1)
      if (c == "\"") {
        j = str_end(s, i); if (j == 0) return 0
        if (depth == 1 && substr(s, j + 1, 1) == ":" && str_at(s, i) == key) return j + 1
        i = j + 1; continue
      }
      if (c == "{") depth++
      else if (c == "}") depth--
      i++
    }
    return 0
  }
  {
    s = $0
    i = index(s, "{"); if (i == 0) exit 1
    i = i + 1
    # split() returns 0 for an empty path, so the root case skips this loop
    n = split(path, parts, "/")
    for (p = 1; p <= n; p++) {
      if (parts[p] == "") continue
      k = find_key(s, i, parts[p]); if (k == 0) exit 1
      if (substr(s, k, 2) != ":{") exit 1
      i = k + 2
    }
    k = find_key(s, i, field); if (k == 0) exit 1
    if (substr(s, k, 2) != ":\"") exit 1
    print str_at(s, k + 1); exit 0
  }'
}

# Sets globals: MANIFEST_VERSION, MANIFEST_FILENAME, MANIFEST_SHA256
parse_manifest() {
  local manifest="$1" platform="$2"

  if command -v jq &>/dev/null; then
    # A body that is not JSON at all -- a captive portal or a proxy answering the
    # manifest URL with an HTML page and HTTP 200 -- makes jq print its own
    # `jq: parse error` line and exit 5, which `set -e` then hands back as the
    # script's exit code. The fallback below reports the same input through
    # error(), exit 1, so validate once here and keep the two paths
    # indistinguishable to whoever is reading the terminal.
    printf '%s' "$manifest" | jq empty 2>/dev/null \
      || error "Failed to parse version from manifest."

    # `// empty` matches the two lines below. Without it a manifest with no
    # version yields the STRING "null", which is non-empty, so the guard below
    # passes and the download URL becomes <cdn>/null/<filename> (CLI-1292).
    #
    # `2>/dev/null || true` for the same reason the fallback's three reads carry
    # `|| true`: valid JSON in the wrong SHAPE (a platform entry that is a string
    # rather than an object) also makes jq exit 5, and the guards below say
    # something useful where a raw `jq: error (at <stdin>:0)` line does not.
    MANIFEST_VERSION=$(printf '%s' "$manifest" | jq -r '.version // empty' 2>/dev/null || true)
    MANIFEST_FILENAME=$(printf '%s' "$manifest" | jq -r ".binaries[\"${platform}\"].filename // empty" 2>/dev/null || true)
    MANIFEST_SHA256=$(printf '%s'  "$manifest"  | jq -r ".binaries[\"${platform}\"].sha256 // empty"   2>/dev/null || true)
  else
    # Compact JSON for pattern matching (no jq dependency)
    local compact
    compact=$(printf '%s' "$manifest" \
      | tr -d '\n\r' \
      | sed 's/[[:space:]]*:[[:space:]]*/:/g' \
      | sed 's/[[:space:]]*{[[:space:]]*/\{/g' \
      | sed 's/[[:space:]]*}[[:space:]]*/\}/g' \
      | sed 's/[[:space:]]*,[[:space:]]*/,/g')

    # `|| true` on all three so a field the manifest lacks reaches the guards
    # below with a friendly message. Without it `set -euo pipefail` aborts on the
    # failed pipeline first, which is why the version guard was unreachable here.
    MANIFEST_VERSION=$(json_string_field  "$compact" ""                    version  || true)
    MANIFEST_FILENAME=$(json_string_field "$compact" "binaries/$platform"  filename || true)
    MANIFEST_SHA256=$(json_string_field   "$compact" "binaries/$platform"  sha256   || true)
  fi

  [ -n "$MANIFEST_VERSION"  ] || error "Failed to parse version from manifest."
  [ -n "$MANIFEST_FILENAME" ] || error "No binary available for platform: ${platform}."
  [ -n "$MANIFEST_SHA256"   ] || error "No checksum available for platform: ${platform}."
}

# ─── SHA-256 verification ─────────────────────────────────────────────────────
verify_sha256() {
  local file="$1" expected="$2"
  local actual

  if command -v shasum &>/dev/null; then
    actual=$(shasum -a 256 "$file" | awk '{print $1}')
  elif command -v sha256sum &>/dev/null; then
    actual=$(sha256sum "$file" | awk '{print $1}')
  else
    # Fail closed: never install an unverified binary. Matches install.ps1,
    # which always verifies via Get-FileHash.
    error "Cannot verify download: neither 'shasum' nor 'sha256sum' is available. Install one (e.g. coreutils) and re-run."
  fi

  if [ "$actual" != "$expected" ]; then
    error "SHA-256 verification failed.\n    Expected: ${expected}\n    Actual:   ${actual}"
  fi
}

# ─── Shell PATH configuration ─────────────────────────────────────────────────
# What add_to_path appends and greps for depends on the layout:
#   home — source the install dir's env file (which prepends BIN_DIR to PATH)
#   xdg  — export ~/.local/bin onto PATH directly (there is no env file)
# The xdg needles are the exact snippet lines we write (a broad ".local/bin"
# needle could match an unrelated comment or a login-only PATH tweak and skip
# a needed rc update). The fish file gets its own needle: it never contains
# the bash/zsh snippet line.
# The bash/zsh snippet guards against double-prepending (nested shells,
# re-sourced rc files), same as the home-layout env file and the fish snippet.
# Older installers appended the bare unguarded export instead — add_to_path
# whole-line-matches either variant, so re-runs stay idempotent across
# installer versions.
if [ "$LAYOUT" = "xdg" ]; then
  SHELL_SNIPPET_LINE='case ":${PATH}:" in *:"$HOME/.local/bin":*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac'
  SHELL_SNIPPET_LEGACY_LINE='export PATH="$HOME/.local/bin:$PATH"'
  FISH_SNIPPET_NEEDLE='set -x PATH "$HOME/.local/bin" $PATH'
else
  SHELL_SNIPPET_LINE=". \"$INSTALL_DIR/env\""
  FISH_SNIPPET_NEEDLE="$INSTALL_DIR"
fi

# Returns: 0 = added, 1 = not added (no file / no write), 2 = already present
add_to_path() {
  local shell_config="$1"
  [ -f "$shell_config" ] || return 1

  if ! [ -w "$shell_config" ]; then
    warn "Cannot write to $shell_config (permission denied), skipping."
    return 1
  fi

  # Exact whole-line match against the canonical line we append — a
  # commented-out variant or an unrelated mention of the install dir must not
  # count as configured. Every installer version has written this exact line
  # per layout; the xdg layout additionally matches the bare export a previous
  # installer version appended.
  if grep -qxF "$SHELL_SNIPPET_LINE" "$shell_config" 2>/dev/null; then
    return 2  # already configured
  fi
  if [ "$LAYOUT" = "xdg" ] && grep -qxF "$SHELL_SNIPPET_LEGACY_LINE" "$shell_config" 2>/dev/null; then
    return 2  # already configured
  fi

  {
    echo ""
    echo "# Unity CLI"
    echo "$SHELL_SNIPPET_LINE"
  } >> "$shell_config"
  return 0
}

# Tries one shell config file. Sets PATH_CONFIGURED on any final outcome, and
# SHELL_CONFIG_UPDATED only when the file was modified (an already-configured
# file leaves it empty). Returns 0 when the outcome is final (added, or already
# configured); returns 1 when the file was unusable and the caller should try
# the next candidate.
try_shell_config() {
  local shell_config="$1" r=0
  add_to_path "$shell_config" || r=$?
  if [ "$r" -eq 0 ]; then
    PATH_CONFIGURED="true"
    SHELL_CONFIG_UPDATED="$shell_config"
    return 0
  fi
  if [ "$r" -eq 2 ]; then
    PATH_CONFIGURED="already"
    return 0
  fi
  return 1
}

configure_shell_path() {
  PATH_CONFIGURED="false"
  SHELL_CONFIG_UPDATED=""

  case "${SHELL:-}" in
    */zsh)
      local zsh_dir="${ZDOTDIR:-$HOME}"
      # Fallback: .zshenv (sourced by all zsh session types including IDEs)
      try_shell_config "$zsh_dir/.zshrc" || try_shell_config "$zsh_dir/.zshenv" || true
      ;;
    */bash)
      # Interactive non-login shells (the typical Linux terminal window) read
      # ~/.bashrc, while login shells (macOS Terminal, SSH) read
      # ~/.bash_profile — configuring .bashrc is what makes "restart your
      # terminal" true on Linux. Create it when missing: unlike .bash_profile,
      # a new .bashrc cannot shadow another startup file.
      [ -f "$HOME/.bashrc" ] || touch "$HOME/.bashrc" 2>/dev/null || true
      try_shell_config "$HOME/.bashrc" || true
      # When .bashrc was configured (or already carried the PATH), also update
      # an existing ~/.bash_profile so login shells pick the PATH up too; when
      # .bashrc couldn't be configured, leave .bash_profile alone and let the
      # manual instructions cover both shell types. Never create .bash_profile:
      # a login shell reads only the first of .bash_profile / .bash_login /
      # .profile, so a new .bash_profile would stop bash from reading an
      # existing ~/.profile.
      if [ "$PATH_CONFIGURED" != "false" ] && [ -f "$HOME/.bash_profile" ]; then
        add_to_path "$HOME/.bash_profile" || true
      fi
      ;;
    */fish)
      local fish_dir="${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d"
      local fish_config="$fish_dir/unity-cli.fish"
      if [ -f "$fish_config" ] && grep -qF "$FISH_SNIPPET_NEEDLE" "$fish_config" 2>/dev/null; then
        PATH_CONFIGURED="already"
        return
      fi
      mkdir -p "$fish_dir"
      if [ "$LAYOUT" = "xdg" ]; then
        {
          echo "# Unity CLI"
          echo "if not contains -- \"\$HOME/.local/bin\" \$PATH"
          echo "  set -x PATH \"\$HOME/.local/bin\" \$PATH"
          echo "end"
        } > "$fish_config"
      else
        {
          echo "# Unity CLI"
          echo "source \"$INSTALL_DIR/env.fish\""
        } > "$fish_config"
      fi
      PATH_CONFIGURED="true"
      SHELL_CONFIG_UPDATED="$fish_config"
      ;;
  esac

  # Always succeed: with no usable config file (fresh accounts, containers, CI
  # images) PATH_CONFIGURED stays "false" and the caller prints manual PATH
  # instructions. A non-zero return here would abort the script under `set -e`
  # before the success message.
  return 0
}

# ─── XDG PATH persistence probe ───────────────────────────────────────────────
# ~/.local/bin being on PATH *right now* is not proof future shells get it too:
# the installer may be running in a login shell (SSH) whose ~/.profile added
# it, while a plain terminal reading only ~/.bashrc would miss it — or it may
# be a one-off export in this session. Before trusting PATH, confirm some
# startup file persistently references ~/.local/bin; otherwise write the rc
# snippet anyway (the exact-line grep guard keeps that idempotent).
xdg_path_is_persistent() {
  local f
  for f in /etc/environment /etc/profile /etc/profile.d/*.sh \
    "$HOME/.profile" "$HOME/.bash_profile" "$HOME/.bash_login" "$HOME/.bashrc" \
    "${ZDOTDIR:-$HOME}/.zshenv" "${ZDOTDIR:-$HOME}/.zprofile" "${ZDOTDIR:-$HOME}/.zshrc" \
    "${XDG_CONFIG_HOME:-$HOME/.config}/fish/conf.d/unity-cli.fish"; do
    # Match only non-commented lines: a commented-out PATH tweak (or a `#`
    # earlier on the line) must not count as persistent configuration.
    if [ -f "$f" ] && grep -qsE '^[^#]*\.local/bin' "$f" 2>/dev/null; then
      return 0
    fi
  done
  return 1
}

# ─── Install receipt ──────────────────────────────────────────────────────────
# Record where the binary landed, in the app-data directory the CLI and the Hub
# already share. This is what lets a Hub that is ALREADY RUNNING find a CLI
# installed underneath it: every PATH edit this script makes reaches only
# shells started afterwards, and a Dock-launched macOS Hub reads no shell
# config at all, so `command -v unity` inside that Hub keeps answering
# "nothing" no matter what we write here.
#
# Mirrors src/Modules/InstallReceipt.cs byte for byte (2-space indent,
# camelCase keys, key order, trailing newline) so a receipt is the same
# document whichever transport wrote it. Best-effort throughout: an install
# must never fail over its receipt.
receipt_dir() {
  case "$(uname -s)" in
    Darwin) echo "$HOME/Library/Application Support/UnityHub" ;;
    *)      echo "${XDG_CONFIG_HOME:-$HOME/.config}/unityhub" ;;
  esac
}

# Backslash first, then quote. The reverse order would re-escape the
# backslashes this step introduces.
json_escape() {
  printf '%s' "$1" | sed -e 's/\\/\\\\/g' -e 's/"/\\"/g'
}

write_install_receipt() {
  local version="$1"
  local dir file tmp
  dir="$(receipt_dir)"
  mkdir -p "$dir" 2>/dev/null || return 0
  file="$dir/cli-install.json"
  # Staged then renamed, so a Hub reading concurrently sees the old receipt
  # or the new one, never a half-written document.
  tmp="$file.staging.$$"
  {
    printf '{\n'
    printf '  "path": "%s",\n' "$(json_escape "$BIN_DIR/unity")"
    printf '  "version": "%s",\n' "$(json_escape "$version")"
    printf '  "layout": "%s",\n' "$(json_escape "$LAYOUT")"
    # Milliseconds are hardcoded: `date +%3N` is a GNU extension and this
    # script runs on macOS's BSD date too.
    printf '  "installedAt": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%S.000Z)"
    printf '}\n'
  } > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 0; }
  mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
  return 0
}

# ─── Legacy install migration (xdg layout only) ───────────────────────────────
# A pre-existing ~/.unity/bin/unity would shadow the new ~/.local/bin/unity:
# shell configs source ~/.unity/env from .bashrc/.zshrc, which prepends
# ~/.unity/bin to PATH *after* login scripts put ~/.local/bin there — so the
# stale binary would keep winning. Remove the old binary and neuter the env
# files (shell configs may still source them, so deleting would make every
# new shell print an error).
migrate_legacy_install() {
  [ "$LAYOUT" = "xdg" ] || return 0
  local legacy_dir="$HOME/.unity"
  local legacy_bin="$legacy_dir/bin/unity"
  [ -f "$legacy_bin" ] || return 0

  info "Removing previous install at ~/.unity/bin/unity (replaced by $BIN_DIR/unity)..."
  # Migration failures must not abort the script (`set -e`): the new binary is
  # already installed at this point, and dying here would skip PATH setup and
  # the success message. Warn, keep going — stubbing the env files below still
  # takes ~/.unity/bin off new shells' PATH even when the old binary can't be
  # removed, so the new install wins either way.
  if ! rm -f "$legacy_bin" "$legacy_bin.previous" "$legacy_bin.previous.sha256" 2>/dev/null; then
    warn "Could not remove the old binary at ~/.unity/bin/unity (permission denied?)."
    warn "Remove it manually: rm -f \"$legacy_bin\""
  fi
  rmdir "$legacy_dir/bin" 2>/dev/null || true

  local envf
  for envf in "$legacy_dir/env" "$legacy_dir/env.fish"; do
    if [ -f "$envf" ]; then
      printf '%s\n' "# Unity CLI — install moved to ~/.local/bin; stub kept so old shell-config source lines stay harmless." 2>/dev/null > "$envf" \
        || warn "Could not update $envf — shell configs sourcing it will keep ~/.unity/bin on PATH."
    fi
  done
  rmdir "$legacy_dir" 2>/dev/null || true
}

# ─── Main ─────────────────────────────────────────────────────────────────────
print_get_started() {
  echo -e "  ${BOLD}Get started:${NC}"
  echo    "    unity --help           Show available commands"
  echo    "    unity editors list     List installed Unity editors"
  echo    "    unity install          Install a Unity editor"
  echo    "    unity self-update      Update to the latest CLI version"
  echo ""
  echo -e "  AI agents: start with ${BLUE}UNITY_CLI_FTUE=1 unity auth status --json${NC}"
}

main() {
  echo ""
  echo -e "${BOLD}Unity CLI Installer${NC}"
  echo ""

  check_requirements

  local platform
  platform=$(detect_platform)

  # Before any download or filesystem change: on Linux these binaries need a
  # glibc floor the host may not meet, and the failure mode without this check
  # is a "successful" install of something whose loader dies before main.
  case "$platform" in
    linux-*) check_glibc ;;
  esac

  # Resolve the manifest for the version we're installing. Each release
  # publishes its own manifest at <version>/latest.json (always that name,
  # regardless of channel) alongside the channel manifest, which only ever
  # describes the latest release. So:
  #   - pinned (UNITY_CLI_VERSION): go straight to that release's manifest. The
  #     channel manifest would be the wrong version anyway, and skipping it
  #     avoids a needless request and failure point.
  #   - unpinned: resolve "latest" from the channel manifest.
  # Either way, MANIFEST_FILENAME/MANIFEST_SHA256 end up matching the binary we
  # download, so checksum verification is against the right release.
  local manifest version
  if [ -n "${UNITY_CLI_VERSION:-}" ]; then
    version="$UNITY_CLI_VERSION"
    info "Using requested version: $version"
    manifest=$(http_get "${CDN_BASE}${version}/latest.json") \
      || error "Failed to fetch manifest for version '$version'. Check that it is a published version.\n\n    ${CDN_BASE}${version}/latest.json"
    parse_manifest "$manifest" "$platform"
    [ "$MANIFEST_VERSION" = "$version" ] \
      || error "Version manifest mismatch: requested '$version' but manifest reports '$MANIFEST_VERSION'."
  else
    info "Checking for latest version..."
    if ! manifest=$(http_get "${CDN_BASE}${MANIFEST_FILE}"); then
      # No channel was requested (MANIFEST_FILE defaults to latest.json) and
      # the CLI has not reached GA yet, so the stable manifest may not exist
      # -- a 404, not a network problem. Fall back to beta rather than
      # failing outright; a genuinely unset UNITY_CLI_CHANNEL is the only
      # case this applies to, an explicitly-requested channel still fails
      # loudly. Once GA ships, latest.json stops 404ing and this fallback
      # never fires again.
      if [ -z "${UNITY_CLI_CHANNEL:-}" ] && [ "$(http_status "${CDN_BASE}${MANIFEST_FILE}")" = "404" ]; then
        info "No stable release yet -- installing the latest beta instead."
        manifest=$(http_get "${CDN_BASE}latest-beta.json") \
          || error "Failed to fetch version manifest. Check your network connection.\n\n    ${CDN_BASE}latest-beta.json"
      else
        error "Failed to fetch version manifest. Check your network connection.\n\n    ${CDN_BASE}${MANIFEST_FILE}"
      fi
    fi
    parse_manifest "$manifest" "$platform"
    version="$MANIFEST_VERSION"
  fi

  info "Installing version $version for $platform..."

  # Create directories
  mkdir -p "$BIN_DIR"

  # Download binary to a temp file (not `local` — the EXIT trap runs after main() returns)
  tmp_file="$(mktemp)"
  trap 'rm -f "$tmp_file"' EXIT

  local binary_url="${CDN_BASE}${version}/${MANIFEST_FILENAME}"
  info "Downloading binary..."
  http_download "$binary_url" "$tmp_file" \
    || error "Failed to download binary from:\n\n    $binary_url"

  # Verify checksum
  info "Verifying checksum..."
  verify_sha256 "$tmp_file" "$MANIFEST_SHA256"

  # In the xdg layout the bin dir is shared with other tools, so an existing
  # `unity` there is not necessarily ours — it may be the user's own script
  # (e.g. an editor-launcher wrapper). Replacing a previous CLI install is
  # routine and stays quiet; anything else gets a loud warning. Our compiled
  # binaries are all far larger than 10 MB, so size is a reliable signal.
  if [ "$LAYOUT" = "xdg" ] && [ -f "$BIN_DIR/unity" ]; then
    local existing_size
    # Some wc implementations (BSD/macOS, some busybox) pad the count with
    # leading spaces, which breaks the numeric [ -lt ] test — strip all
    # non-digits and normalize empty to 0.
    existing_size=$( { wc -c 2>/dev/null < "$BIN_DIR/unity" || echo 0; } | tr -cd '0-9')
    if [ "${existing_size:-0}" -lt 10000000 ]; then
      warn "Replacing existing $BIN_DIR/unity, which does not look like a previous Unity CLI install."
    fi
  fi

  # Install the binary
  cp "$tmp_file" "$BIN_DIR/unity"
  chmod +x "$BIN_DIR/unity"

  if [ "$LAYOUT" = "home" ]; then
    # Write POSIX sh env file (sourced from .bashrc / .zshrc)
    cat > "$INSTALL_DIR/env" << ENVEOF
# Unity CLI — added by installer
case ":\${PATH}:" in
  *:"${BIN_DIR}":*) ;;
  *) export PATH="${BIN_DIR}:\$PATH" ;;
esac
ENVEOF

    # Write fish env file
    cat > "$INSTALL_DIR/env.fish" << FISHEOF
# Unity CLI — added by installer
if not contains -- "${BIN_DIR}" \$PATH
  set -x PATH "${BIN_DIR}" \$PATH
end
FISHEOF
  fi

  migrate_legacy_install

  write_install_receipt "$version"

  # Configure shell PATH. In the xdg layout, ~/.local/bin is usually already
  # on PATH (login scripts on most distros add it) — only skip the shell
  # configs when it is on PATH *and* a startup file persistently provides it.
  if [ "$LAYOUT" = "xdg" ]; then
    case ":${PATH}:" in
      *:"$BIN_DIR":*)
        if xdg_path_is_persistent; then
          PATH_CONFIGURED="already"
          SHELL_CONFIG_UPDATED=""
        else
          configure_shell_path
        fi
        ;;
      *)
        configure_shell_path
        ;;
    esac
  else
    configure_shell_path
  fi

  # ─── Success ──────────────────────────────────────────────────────────────
  local display_install="${INSTALL_DIR/#$HOME/\~}"

  echo ""
  echo -e "  ${GREEN}✔${NC}  ${BOLD}Unity CLI $version installed!${NC}"
  echo ""
  print_get_started
  echo ""

  if [ "$PATH_CONFIGURED" = "true" ] && [ -n "$SHELL_CONFIG_UPDATED" ]; then
    local display_config="${SHELL_CONFIG_UPDATED/#$HOME/\~}"
    echo -e "  Run ${BLUE}source $display_config${NC} or restart your terminal to use ${BOLD}unity${NC}."
  elif [ "$PATH_CONFIGURED" = "already" ]; then
    if command -v unity >/dev/null 2>&1; then
      echo -e "  ${BOLD}unity${NC} is ready — run ${BLUE}unity --help${NC}."
    else
      echo -e "  ${BOLD}unity${NC} is ready — restart your terminal to run ${BLUE}unity --help${NC}."
    fi
  elif [ "$LAYOUT" = "xdg" ]; then
    echo -e "  ${YELLOW}note${NC}: Add unity to your PATH:"
    echo ""
    echo    "    export PATH=\"\$HOME/.local/bin:\$PATH\""
    echo ""
    echo -e "  Or run unity directly: ${BLUE}${BIN_DIR_REF}/unity${NC}"
  else
    echo -e "  ${YELLOW}note${NC}: Add unity to your PATH by sourcing the env file:"
    echo ""
    echo    "    . \"${display_install}/env\""
    echo ""
    echo -e "  Or run unity directly: ${BLUE}${BIN_DIR_REF}/unity${NC}"
  fi

  echo ""
}

# Run unless this file is being SOURCED — apps/cli/install-sh-manifest.spec.ts
# sources it to call parse_manifest directly. `curl | bash` leaves BASH_SOURCE
# empty, so the empty case must still run main.
if [ -z "${BASH_SOURCE[0]:-}" ] || [ "${BASH_SOURCE[0]}" = "$0" ]; then
  main "$@"
fi
