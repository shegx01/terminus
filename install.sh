#!/usr/bin/env bash
# termbot installer — install, upgrade, or uninstall termbot
# https://github.com/shegx01/termbot
#
# Usage:
#   curl -sSL https://raw.githubusercontent.com/shegx01/termbot/main/install.sh | bash
#   bash install.sh [--quick] [--upgrade] [--uninstall]
#
# The entire script is wrapped in main() so that a partial download via
# curl|bash never executes an incomplete script.

set -euo pipefail

# =============================================================================
# Constants
# =============================================================================

REPO="shegx01/termbot"
GITHUB_RELEASES="https://api.github.com/repos/${REPO}/releases/latest"
BINARY_NAME="termbot"
INSTALL_DIR="${HOME}/.local/bin"
CONFIG_DIR="${HOME}/.config/termbot"
CONFIG_FILE="${CONFIG_DIR}/termbot.toml"
VERSION_FILE="${CONFIG_DIR}/.installed-version"
LOG_DIR="${CONFIG_DIR}/logs"
BINARY_PATH="${INSTALL_DIR}/${BINARY_NAME}"
BACKUP_PATH="${INSTALL_DIR}/${BINARY_NAME}.bak"
UPDATE_CHECK_PATH="${INSTALL_DIR}/termbot-update-check"
WRAPPER_PATH="${INSTALL_DIR}/termbot-wrapper"

# macOS paths
LAUNCHD_SERVICE="${HOME}/Library/LaunchAgents/com.termbot.agent.plist"
LAUNCHD_UPDATE="${HOME}/Library/LaunchAgents/com.termbot.update-check.plist"

# Linux paths
SYSTEMD_DIR="${HOME}/.config/systemd/user"
SYSTEMD_SERVICE="${SYSTEMD_DIR}/termbot.service"
SYSTEMD_UPDATE_SERVICE="${SYSTEMD_DIR}/termbot-update-check.service"
SYSTEMD_UPDATE_TIMER="${SYSTEMD_DIR}/termbot-update-check.timer"

# =============================================================================
# Global state (set by interactive prompts)
# =============================================================================

PLATFORM=""          # telegram | slack | both
TG_BOT_TOKEN=""
TG_USER_ID=""
SL_BOT_TOKEN=""
SL_APP_TOKEN=""
SL_USER_ID=""
SL_CHANNEL_ID=""

# Flags
QUICK=false
UPGRADE=false
UNINSTALL=false

# =============================================================================
# Colors (disabled when stderr is not a terminal)
# =============================================================================

setup_colors() {
  if [ -t 2 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    DIM='\033[2m'
    NC='\033[0m'
  else
    RED='' GREEN='' YELLOW='' BLUE='' CYAN='' BOLD='' DIM='' NC=''
  fi
}

# =============================================================================
# Output helpers (all go to stderr to keep stdout clean)
# =============================================================================

info()    { printf "  ${GREEN}✓${NC} %s\n" "$1" >&2; }
warn()    { printf "  ${YELLOW}!${NC} %s\n" "$1" >&2; }
error()   { printf "  ${RED}✗${NC} %s\n" "$1" >&2; }
step()    { printf "\n${BOLD}${BLUE}▸ %s${NC}\n" "$1" >&2; }
hint()    { if [ "$QUICK" = false ]; then printf "    ${DIM}%s${NC}\n" "$1" >&2; fi; }
hint_always() { printf "    ${DIM}%s${NC}\n" "$1" >&2; }

# =============================================================================
# Input helpers (read from /dev/tty so curl|bash works)
# =============================================================================

prompt() {
  local message="$1"
  local default="${2:-}"
  local result

  if [ -n "$default" ]; then
    printf "  ${BOLD}%s${NC} [%s]: " "$message" "$default" >&2
  else
    printf "  ${BOLD}%s${NC}: " "$message" >&2
  fi

  read -r result < /dev/tty || true

  if [ -z "$result" ] && [ -n "$default" ]; then
    result="$default"
  fi

  printf "%s" "$result"
}

prompt_choice() {
  local message="$1"
  shift
  local i=1
  local choice

  printf "\n  ${BOLD}%s${NC}\n" "$message" >&2
  for opt in "$@"; do
    printf "    ${CYAN}%d)${NC} %s\n" "$i" "$opt" >&2
    i=$((i + 1))
  done
  printf "  ${BOLD}>${NC} " >&2

  read -r choice < /dev/tty || true
  printf "%s" "$choice"
}

prompt_yn() {
  local message="$1"
  local default="${2:-y}"
  local result

  if [ "$default" = "y" ]; then
    printf "  ${BOLD}%s${NC} [Y/n]: " "$message" >&2
  else
    printf "  ${BOLD}%s${NC} [y/N]: " "$message" >&2
  fi

  read -r result < /dev/tty || true
  result="${result:-$default}"
  result="$(printf "%s" "$result" | tr '[:upper:]' '[:lower:]')"

  [ "$result" = "y" ] || [ "$result" = "yes" ]
}

# =============================================================================
# OS-native notifications
# =============================================================================

notify_os() {
  local title="$1"
  local message="$2"

  case "$(uname -s)" in
    Darwin)
      osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true
      ;;
    Linux)
      if command -v notify-send >/dev/null 2>&1; then
        notify-send "$title" "$message" 2>/dev/null || true
      fi
      ;;
  esac
}

# =============================================================================
# Platform detection
# =============================================================================

detect_os() {
  case "$(uname -s)" in
    Darwin) printf "macos" ;;
    Linux)  printf "linux" ;;
    *)      error "Unsupported OS: $(uname -s). termbot supports macOS and Linux."; exit 1 ;;
  esac
}

detect_arch() {
  case "$(uname -m)" in
    x86_64|amd64)  printf "x86_64" ;;
    aarch64|arm64) printf "aarch64" ;;
    *)             error "Unsupported architecture: $(uname -m)"; exit 1 ;;
  esac
}

get_target() {
  local os arch
  os="$(detect_os)"
  arch="$(detect_arch)"

  case "${os}-${arch}" in
    macos-x86_64)  printf "x86_64-apple-darwin" ;;
    macos-aarch64) printf "aarch64-apple-darwin" ;;
    linux-x86_64)  printf "x86_64-unknown-linux-gnu" ;;
    linux-aarch64) printf "aarch64-unknown-linux-gnu" ;;
    *)             error "No pre-built binary for ${os} ${arch}"; exit 1 ;;
  esac
}

detect_package_manager() {
  if command -v brew >/dev/null 2>&1; then
    printf "brew"
  elif command -v apt-get >/dev/null 2>&1; then
    printf "apt"
  elif command -v dnf >/dev/null 2>&1; then
    printf "dnf"
  elif command -v yum >/dev/null 2>&1; then
    printf "yum"
  elif command -v pacman >/dev/null 2>&1; then
    printf "pacman"
  else
    printf "unknown"
  fi
}

# =============================================================================
# Dependency checks
# =============================================================================

check_curl() {
  if ! command -v curl >/dev/null 2>&1; then
    error "curl is required but not found. Please install curl first."
    exit 1
  fi
}

check_tmux() {
  if command -v tmux >/dev/null 2>&1; then
    info "tmux found: $(tmux -V)"
    return 0
  fi

  warn "tmux is required but not found."

  local pm
  pm="$(detect_package_manager)"

  if [ "$pm" = "unknown" ]; then
    error "Could not detect a package manager. Please install tmux manually and re-run."
    exit 1
  fi

  if prompt_yn "Install tmux via ${pm}?"; then
    install_tmux "$pm"
  else
    error "tmux is required. Install it and try again."
    exit 1
  fi
}

install_tmux() {
  local pm="$1"
  step "Installing tmux via ${pm}"

  case "$pm" in
    brew)   brew install tmux >&2 ;;
    apt)    sudo apt-get update -qq >&2 && sudo apt-get install -y tmux >&2 ;;
    dnf)    sudo dnf install -y tmux >&2 ;;
    yum)    sudo yum install -y tmux >&2 ;;
    pacman) sudo pacman -S --noconfirm tmux >&2 ;;
  esac

  if command -v tmux >/dev/null 2>&1; then
    info "tmux installed: $(tmux -V)"
  else
    error "tmux installation failed. Install it manually and re-run."
    exit 1
  fi
}

check_claude() {
  if command -v claude >/dev/null 2>&1; then
    info "Claude Code CLI found"
    return 0
  fi

  error "Claude Code CLI is required but not found."
  hint_always "Install it with: npm i -g @anthropic-ai/claude-code"
  hint_always "Then authenticate: claude login"
  exit 1
}

# =============================================================================
# Token validation
# =============================================================================

validate_telegram_token() {
  # Format: digits:alphanumeric  e.g. 7012345678:AAHxyz...
  case "$1" in
    [0-9]*:*) return 0 ;;
    *)        return 1 ;;
  esac
}

validate_telegram_user_id() {
  case "$1" in
    ''|*[!0-9]*) return 1 ;;
    *)           return 0 ;;
  esac
}

validate_slack_bot_token() {
  case "$1" in
    xoxb-*) return 0 ;;
    *)      return 1 ;;
  esac
}

validate_slack_app_token() {
  case "$1" in
    xapp-*) return 0 ;;
    *)      return 1 ;;
  esac
}

# =============================================================================
# Interactive configuration
# =============================================================================

prompt_platform_choice() {
  local choice
  choice="$(prompt_choice "Which platform will you use?" "Telegram" "Slack" "Both")"

  case "$choice" in
    1) PLATFORM="telegram" ;;
    2) PLATFORM="slack" ;;
    3) PLATFORM="both" ;;
    *)
      warn "Invalid choice — enter 1, 2, or 3."
      prompt_platform_choice
      ;;
  esac
}

prompt_telegram() {
  step "Telegram configuration"

  hint "You'll need your bot token and user ID."
  hint ""

  # Bot token
  while true; do
    hint "To get a bot token:"
    hint "  1. Message @BotFather on Telegram"
    hint "  2. Send /newbot and follow the prompts"
    hint "  3. Copy the token (looks like 7012345678:AAH...)"
    hint ""

    TG_BOT_TOKEN="$(prompt "Telegram bot token")"

    if validate_telegram_token "$TG_BOT_TOKEN"; then
      info "Token format valid"
      break
    else
      warn "That doesn't look like a Telegram token (expected: 1234567890:AAHx...)"
    fi
  done

  # User ID
  while true; do
    hint ""
    hint "To get your user ID:"
    hint "  1. Message @userinfobot on Telegram"
    hint "  2. It replies with your numeric ID"
    hint ""

    TG_USER_ID="$(prompt "Your Telegram user ID")"

    if validate_telegram_user_id "$TG_USER_ID"; then
      info "User ID format valid"
      break
    else
      warn "User ID should be a number (e.g., 123456789)"
    fi
  done
}

prompt_slack() {
  step "Slack configuration"

  hint "You'll need tokens from your Slack app."
  hint "Create one at: https://api.slack.com/apps"
  hint ""

  # Bot token
  while true; do
    hint "Bot token: OAuth & Permissions -> Bot User OAuth Token"
    hint "  Required scopes: chat:write, channels:history, channels:read"
    hint ""

    SL_BOT_TOKEN="$(prompt "Slack bot token (xoxb-...)")"

    if validate_slack_bot_token "$SL_BOT_TOKEN"; then
      info "Bot token format valid"
      break
    else
      warn "Slack bot token should start with xoxb-"
    fi
  done

  # App token
  while true; do
    hint ""
    hint "App token: Settings -> Socket Mode -> Generate token"
    hint "  Required scope: connections:write"
    hint ""

    SL_APP_TOKEN="$(prompt "Slack app token (xapp-...)")"

    if validate_slack_app_token "$SL_APP_TOKEN"; then
      info "App token format valid"
      break
    else
      warn "Slack app token should start with xapp-"
    fi
  done

  # Member ID
  hint ""
  hint "Member ID: Click your profile picture -> Profile -> ... -> Copy member ID"
  hint ""
  SL_USER_ID="$(prompt "Your Slack member ID (U...)")"
  info "Member ID set"

  # Channel ID
  hint ""
  hint "Channel ID: Right-click channel -> View channel details -> ID at bottom"
  hint ""
  SL_CHANNEL_ID="$(prompt "Slack channel ID (C...)")"
  info "Channel ID set"
}

# =============================================================================
# Config file writer
# =============================================================================

write_config() {
  mkdir -p "$CONFIG_DIR"

  {
    printf "# termbot configuration\n"
    printf "# Generated by install.sh on %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
    printf "# Docs: https://github.com/%s#configuration\n\n" "$REPO"

    # [auth]
    printf "[auth]\n"
    if [ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ]; then
      printf "telegram_user_id = %s\n" "$TG_USER_ID"
    fi
    if [ "$PLATFORM" = "slack" ] || [ "$PLATFORM" = "both" ]; then
      printf "slack_user_id = \"%s\"\n" "$SL_USER_ID"
    fi

    # [telegram]
    if [ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ]; then
      printf "\n[telegram]\n"
      printf "bot_token = \"%s\"\n" "$TG_BOT_TOKEN"
    fi

    # [slack]
    if [ "$PLATFORM" = "slack" ] || [ "$PLATFORM" = "both" ]; then
      printf "\n[slack]\n"
      printf "bot_token = \"%s\"\n" "$SL_BOT_TOKEN"
      printf "app_token = \"%s\"\n" "$SL_APP_TOKEN"
      printf "channel_id = \"%s\"\n" "$SL_CHANNEL_ID"
    fi

    # [blocklist]
    cat <<'BLOCKLIST'

[blocklist]
patterns = [
  "rm\\s+-[a-z]*f[a-z]*r[a-z]*\\s+/",
  "sudo\\s+",
  ":\\(\\)\\{\\s*:\\|:\\&\\s*\\};:",
  "mkfs\\.",
  "dd\\s+if=",
]
BLOCKLIST

    # [streaming]
    cat <<'STREAMING'

[streaming]
edit_throttle_ms = 2000
poll_interval_ms = 250
chunk_size = 4000
offline_buffer_max_bytes = 1048576
max_sessions = 10
STREAMING
  } > "$CONFIG_FILE"

  chmod 600 "$CONFIG_FILE"
  info "Config written to ${CONFIG_FILE}"
}

# =============================================================================
# Binary download
# =============================================================================

get_latest_version() {
  curl -fsSL "$GITHUB_RELEASES" 2>/dev/null \
    | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' \
    || printf "unknown"
}

download_binary() {
  local target="$1"
  local url="https://github.com/${REPO}/releases/latest/download/${BINARY_NAME}-${target}"
  local tmp_file

  step "Downloading termbot"
  hint_always "Target: ${target}"
  hint_always "URL:    ${url}"

  mkdir -p "$INSTALL_DIR"

  tmp_file="$(mktemp "${INSTALL_DIR}/${BINARY_NAME}.XXXXXX")"

  if ! curl -fSL --progress-bar -o "$tmp_file" "$url" 2>&2; then
    rm -f "$tmp_file"
    error "Download failed. Check your internet connection and try again."
    exit 1
  fi

  chmod +x "$tmp_file"

  # Atomic swap — back up existing binary
  if [ -f "$BINARY_PATH" ]; then
    mv "$BINARY_PATH" "$BACKUP_PATH"
    info "Previous binary backed up to ${BACKUP_PATH}"
  fi

  mv "$tmp_file" "$BINARY_PATH"
  info "Binary installed to ${BINARY_PATH}"

  # Record installed version
  local version
  version="$(get_latest_version)"
  mkdir -p "$CONFIG_DIR"
  printf "%s" "$version" > "$VERSION_FILE"
}

# =============================================================================
# PATH management
# =============================================================================

ensure_path() {
  case ":${PATH}:" in
    *":${INSTALL_DIR}:"*) return 0 ;;
  esac

  warn "${INSTALL_DIR} is not in your PATH"

  local shell_rc=""
  case "${SHELL:-/bin/bash}" in
    */zsh)  shell_rc="${HOME}/.zshrc" ;;
    */bash) shell_rc="${HOME}/.bashrc" ;;
    *)      shell_rc="${HOME}/.profile" ;;
  esac

  if prompt_yn "Add ${INSTALL_DIR} to PATH in ${shell_rc}?"; then
    printf '\n# Added by termbot installer\nexport PATH="${HOME}/.local/bin:${PATH}"\n' >> "$shell_rc"
    info "PATH updated in ${shell_rc}"
    hint_always "Run: source ${shell_rc}  (or open a new terminal)"
    export PATH="${INSTALL_DIR}:${PATH}"
  else
    warn "Add ${INSTALL_DIR} to your PATH manually."
  fi
}

# =============================================================================
# Service PATH — discover where tmux and claude live at install time
# =============================================================================

build_service_path() {
  local paths="${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin"

  # Homebrew (Apple Silicon + Intel)
  [ -d "/opt/homebrew/bin" ] && paths="/opt/homebrew/bin:${paths}"

  # tmux directory
  local tmux_dir
  tmux_dir="$(dirname "$(command -v tmux 2>/dev/null)" 2>/dev/null)" || true
  case ":${paths}:" in *":${tmux_dir}:"*) ;; *) [ -n "$tmux_dir" ] && paths="${tmux_dir}:${paths}" ;; esac

  # claude directory
  local claude_dir
  claude_dir="$(dirname "$(command -v claude 2>/dev/null)" 2>/dev/null)" || true
  case ":${paths}:" in *":${claude_dir}:"*) ;; *) [ -n "$claude_dir" ] && paths="${claude_dir}:${paths}" ;; esac

  # npm global bin (common claude location)
  local npm_bin
  npm_bin="$(npm bin -g 2>/dev/null)" || true
  case ":${paths}:" in *":${npm_bin}:"*) ;; *) [ -n "$npm_bin" ] && paths="${npm_bin}:${paths}" ;; esac

  printf "%s" "$paths"
}

# =============================================================================
# Service installation — Linux (systemd user units)
# =============================================================================

install_service_linux() {
  step "Installing systemd service"

  local svc_path
  svc_path="$(build_service_path)"

  mkdir -p "$SYSTEMD_DIR"
  mkdir -p "$LOG_DIR"

  cat > "$SYSTEMD_SERVICE" <<EOF
[Unit]
Description=termbot - terminal control from Telegram/Slack
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BINARY_PATH}
WorkingDirectory=${HOME}
Environment=TERMBOT_CONFIG=${CONFIG_FILE}
Environment=PATH=${svc_path}
Restart=on-failure
RestartSec=10
StandardOutput=append:${LOG_DIR}/termbot.log
StandardError=append:${LOG_DIR}/termbot.log

# Send OS notification on crash
ExecStopPost=-/bin/sh -c 'if [ "\$SERVICE_RESULT" != "success" ]; then ${UPDATE_CHECK_PATH} --health-notify 2>/dev/null; fi'

[Install]
WantedBy=default.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable termbot.service >/dev/null 2>&1
  info "systemd service installed and enabled"
}

install_update_timer_linux() {
  step "Installing daily update check"

  cat > "$SYSTEMD_UPDATE_SERVICE" <<EOF
[Unit]
Description=Check for termbot updates

[Service]
Type=oneshot
ExecStart=${UPDATE_CHECK_PATH}
Environment=PATH=${INSTALL_DIR}:/usr/local/bin:/usr/bin:/bin
EOF

  cat > "$SYSTEMD_UPDATE_TIMER" <<EOF
[Unit]
Description=Daily termbot update check

[Timer]
OnCalendar=daily
Persistent=true
RandomizedDelaySec=3600

[Install]
WantedBy=timers.target
EOF

  systemctl --user daemon-reload
  systemctl --user enable --now termbot-update-check.timer >/dev/null 2>&1
  info "Daily update check timer installed"
}

# =============================================================================
# Service installation — macOS (launchd plists)
# =============================================================================

install_service_macos() {
  step "Installing launchd service"

  local svc_path
  svc_path="$(build_service_path)"

  mkdir -p "$(dirname "$LAUNCHD_SERVICE")"
  mkdir -p "$LOG_DIR"

  cat > "$LAUNCHD_SERVICE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.termbot.agent</string>
    <key>ProgramArguments</key>
    <array>
        <string>${WRAPPER_PATH}</string>
    </array>
    <key>WorkingDirectory</key>
    <string>${HOME}</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>TERMBOT_CONFIG</key>
        <string>${CONFIG_FILE}</string>
        <key>PATH</key>
        <string>${svc_path}</string>
    </dict>
    <key>KeepAlive</key>
    <true/>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/termbot.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/termbot.log</string>
    <key>ThrottleInterval</key>
    <integer>10</integer>
</dict>
</plist>
EOF

  info "launchd service installed"
}

install_update_timer_macos() {
  step "Installing daily update check"

  cat > "$LAUNCHD_UPDATE" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.termbot.update-check</string>
    <key>ProgramArguments</key>
    <array>
        <string>${UPDATE_CHECK_PATH}</string>
    </array>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Hour</key>
        <integer>9</integer>
        <key>Minute</key>
        <integer>0</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${LOG_DIR}/update-check.log</string>
    <key>StandardErrorPath</key>
    <string>${LOG_DIR}/update-check.log</string>
</dict>
</plist>
EOF

  info "Daily update check installed (runs at 9:00 AM)"
}

# macOS crash-notification wrapper (launchd lacks ExecStopPost)
write_wrapper_script() {
  cat > "$WRAPPER_PATH" <<EOF
#!/usr/bin/env bash
# termbot wrapper — notify on crash, then exit so launchd restarts
"${BINARY_PATH}"
ec=\$?
if [ \$ec -ne 0 ]; then
  "${UPDATE_CHECK_PATH}" --health-notify 2>/dev/null || true
fi
exit \$ec
EOF
  chmod +x "$WRAPPER_PATH"
}

# =============================================================================
# Update check script (installed to ~/.local/bin/termbot-update-check)
# =============================================================================

write_update_check_script() {
  cat > "$UPDATE_CHECK_PATH" <<'OUTER'
#!/usr/bin/env bash
set -euo pipefail

CONFIG_DIR="${HOME}/.config/termbot"
VERSION_FILE="${CONFIG_DIR}/.installed-version"
LOG_DIR="${CONFIG_DIR}/logs"
REPO="shegx01/termbot"
API="https://api.github.com/repos/${REPO}/releases/latest"

mkdir -p "$LOG_DIR"

log() { printf "[%s] %s\n" "$(date -u +"%Y-%m-%dT%H:%M:%SZ")" "$1" >> "${LOG_DIR}/update-check.log"; }

notify() {
  local title="$1" message="$2"
  case "$(uname -s)" in
    Darwin) osascript -e "display notification \"${message}\" with title \"${title}\"" 2>/dev/null || true ;;
    Linux)  command -v notify-send >/dev/null 2>&1 && notify-send "$title" "$message" 2>/dev/null || true ;;
  esac
  log "${title}: ${message}"
}

# --health-notify: called by service wrapper on crash
if [ "${1:-}" = "--health-notify" ]; then
  notify "termbot" "Service crashed — restarting automatically..."
  exit 0
fi

# Health check: is the service running?
check_health() {
  case "$(uname -s)" in
    Darwin)
      if ! launchctl list com.termbot.agent >/dev/null 2>&1; then
        notify "termbot" "Service is not running. Check: launchctl list com.termbot.agent"
      fi
      ;;
    Linux)
      if command -v systemctl >/dev/null 2>&1; then
        if ! systemctl --user is-active --quiet termbot.service 2>/dev/null; then
          notify "termbot" "Service is not running. Check: systemctl --user status termbot"
        fi
      fi
      ;;
  esac
}

# Update check: is a newer release available?
check_update() {
  local installed latest
  installed="$(cat "$VERSION_FILE" 2>/dev/null || printf "unknown")"
  latest="$(curl -fsSL "$API" 2>/dev/null | grep '"tag_name"' | head -1 | sed 's/.*"tag_name": *"\([^"]*\)".*/\1/' || printf "")"

  if [ -z "$latest" ]; then
    log "Update check failed (network error?)"
    return 0
  fi

  if [ "$installed" != "$latest" ] && [ "$latest" != "unknown" ]; then
    notify "termbot update available" "${latest} (installed: ${installed}). Run: install.sh --upgrade"
  else
    log "Up to date: ${installed}"
  fi
}

check_health
check_update
OUTER

  chmod +x "$UPDATE_CHECK_PATH"
  info "Update check script installed to ${UPDATE_CHECK_PATH}"
}

# =============================================================================
# Service control
# =============================================================================

start_service() {
  local os
  os="$(detect_os)"

  step "Starting termbot"

  case "$os" in
    macos)
      launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_SERVICE" 2>/dev/null \
        || launchctl load "$LAUNCHD_SERVICE" 2>/dev/null \
        || true
      launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_UPDATE" 2>/dev/null \
        || launchctl load "$LAUNCHD_UPDATE" 2>/dev/null \
        || true
      ;;
    linux)
      systemctl --user start termbot.service
      ;;
  esac

  sleep 2

  if verify_running; then
    info "termbot is running"
  else
    warn "termbot may not have started correctly."
    hint_always "Check logs: tail -f ${LOG_DIR}/termbot.log"
  fi
}

stop_service() {
  local os
  os="$(detect_os)"

  case "$os" in
    macos)
      launchctl bootout "gui/$(id -u)/com.termbot.agent" 2>/dev/null \
        || launchctl unload "$LAUNCHD_SERVICE" 2>/dev/null \
        || true
      launchctl bootout "gui/$(id -u)/com.termbot.update-check" 2>/dev/null \
        || launchctl unload "$LAUNCHD_UPDATE" 2>/dev/null \
        || true
      ;;
    linux)
      systemctl --user stop termbot.service 2>/dev/null || true
      systemctl --user stop termbot-update-check.timer 2>/dev/null || true
      systemctl --user disable termbot.service 2>/dev/null || true
      systemctl --user disable termbot-update-check.timer 2>/dev/null || true
      ;;
  esac
}

restart_service() {
  local os
  os="$(detect_os)"

  case "$os" in
    macos)
      launchctl bootout "gui/$(id -u)/com.termbot.agent" 2>/dev/null \
        || launchctl unload "$LAUNCHD_SERVICE" 2>/dev/null \
        || true
      sleep 1
      launchctl bootstrap "gui/$(id -u)" "$LAUNCHD_SERVICE" 2>/dev/null \
        || launchctl load "$LAUNCHD_SERVICE" 2>/dev/null \
        || true
      ;;
    linux)
      systemctl --user restart termbot.service
      ;;
  esac
}

verify_running() {
  local os
  os="$(detect_os)"

  case "$os" in
    macos) pgrep -x termbot >/dev/null 2>&1 ;;
    linux) systemctl --user is-active --quiet termbot.service 2>/dev/null ;;
  esac
}

# =============================================================================
# Main flows
# =============================================================================

do_install() {
  local os target
  os="$(detect_os)"
  target="$(get_target)"

  # Banner
  printf "\n" >&2
  printf "  ${BOLD}termbot installer${NC}\n" >&2
  printf "  ${DIM}https://github.com/%s${NC}\n" "$REPO" >&2

  # Already installed?
  if [ -f "$BINARY_PATH" ]; then
    local installed_version
    installed_version="$(cat "$VERSION_FILE" 2>/dev/null || printf "unknown")"
    printf "\n" >&2
    info "termbot is already installed (${installed_version})"

    if prompt_yn "Upgrade to the latest version?"; then
      do_upgrade
      return
    elif prompt_yn "Reinstall from scratch? (config will be preserved)"; then
      true  # continue with install
    else
      info "No changes made."
      exit 0
    fi
  fi

  # System info
  step "Checking system"
  info "OS: $(uname -s) (${os})"
  info "Architecture: $(uname -m)"
  info "Target: ${target}"

  # Dependencies
  step "Checking dependencies"
  check_curl
  check_tmux
  check_claude

  # Interactive config (skip if config already exists)
  if [ -f "$CONFIG_FILE" ]; then
    info "Existing config found at ${CONFIG_FILE}"
    if ! prompt_yn "Overwrite existing config?"; then
      info "Keeping existing config."
    else
      setup_config
    fi
  else
    setup_config
  fi

  # Download binary
  download_binary "$target"

  # PATH
  ensure_path

  # Helper scripts
  write_update_check_script

  # Service + timer
  case "$os" in
    macos)
      write_wrapper_script
      install_service_macos
      install_update_timer_macos
      ;;
    linux)
      install_service_linux
      install_update_timer_linux
      ;;
  esac

  # Start
  start_service

  # Summary
  print_summary "$os"
}

setup_config() {
  step "Configuration"
  prompt_platform_choice

  if [ "$PLATFORM" = "telegram" ] || [ "$PLATFORM" = "both" ]; then
    prompt_telegram
  fi

  if [ "$PLATFORM" = "slack" ] || [ "$PLATFORM" = "both" ]; then
    prompt_slack
  fi

  step "Writing configuration"
  write_config
}

do_upgrade() {
  local os target
  os="$(detect_os)"
  target="$(get_target)"

  printf "\n" >&2
  printf "  ${BOLD}termbot upgrade${NC}\n\n" >&2

  if [ ! -f "$BINARY_PATH" ]; then
    error "termbot is not installed. Run install.sh without flags to install."
    exit 1
  fi

  local installed_version latest_version
  installed_version="$(cat "$VERSION_FILE" 2>/dev/null || printf "unknown")"
  latest_version="$(get_latest_version)"

  info "Installed: ${installed_version}"
  info "Latest:    ${latest_version}"

  if [ "$installed_version" = "$latest_version" ]; then
    info "Already up to date!"
    exit 0
  fi

  # Download (handles atomic swap + backup)
  download_binary "$target"

  # Refresh helper scripts
  write_update_check_script
  if [ "$os" = "macos" ]; then
    write_wrapper_script
  fi

  # Restart
  step "Restarting service"
  restart_service
  sleep 2

  if verify_running; then
    info "termbot upgraded and running (${latest_version})"
    hint_always "Previous version backed up to ${BACKUP_PATH}"
  else
    warn "termbot may not have started correctly after upgrade."
    hint_always "To rollback: mv '${BACKUP_PATH}' '${BINARY_PATH}'"
    hint_always "Check logs:  tail -f ${LOG_DIR}/termbot.log"
  fi
}

do_uninstall() {
  local os
  os="$(detect_os)"

  printf "\n" >&2
  printf "  ${BOLD}termbot uninstall${NC}\n\n" >&2

  # Stop services
  step "Stopping services"
  stop_service
  info "Services stopped"

  # Remove binary, backup, and helpers
  step "Removing files"
  for f in "$BINARY_PATH" "$BACKUP_PATH" "$UPDATE_CHECK_PATH" "$WRAPPER_PATH"; do
    if [ -f "$f" ]; then
      rm -f "$f"
      info "Removed ${f}"
    fi
  done

  # Remove service files
  case "$os" in
    macos)
      for f in "$LAUNCHD_SERVICE" "$LAUNCHD_UPDATE"; do
        if [ -f "$f" ]; then rm -f "$f"; info "Removed ${f}"; fi
      done
      ;;
    linux)
      for f in "$SYSTEMD_SERVICE" "$SYSTEMD_UPDATE_SERVICE" "$SYSTEMD_UPDATE_TIMER"; do
        if [ -f "$f" ]; then rm -f "$f"; info "Removed ${f}"; fi
      done
      systemctl --user daemon-reload 2>/dev/null || true
      ;;
  esac

  # Remove logs and version file
  if [ -d "$LOG_DIR" ]; then
    rm -rf "$LOG_DIR"
    info "Removed logs"
  fi
  rm -f "$VERSION_FILE" 2>/dev/null || true

  # Config — ask, default to keep
  if [ -f "$CONFIG_FILE" ]; then
    printf "\n" >&2
    if prompt_yn "Delete config file (${CONFIG_FILE})?" "n"; then
      rm -f "$CONFIG_FILE"
      rmdir "$CONFIG_DIR" 2>/dev/null || true
      info "Config removed"
    else
      info "Config preserved at ${CONFIG_FILE}"
    fi
  fi

  printf "\n" >&2
  info "termbot has been uninstalled."
}

# =============================================================================
# Post-install summary
# =============================================================================

print_summary() {
  local os="$1"

  printf "\n${BOLD}${GREEN}  termbot is installed and running!${NC}\n\n" >&2

  printf "  ${BOLD}Files${NC}\n" >&2
  printf "    Binary   %s\n" "$BINARY_PATH" >&2
  printf "    Config   %s\n" "$CONFIG_FILE" >&2
  printf "    Logs     %s\n" "${LOG_DIR}/termbot.log" >&2
  printf "\n" >&2

  printf "  ${BOLD}Commands${NC}\n" >&2
  case "$os" in
    macos)
      printf "    Status     launchctl list com.termbot.agent\n" >&2
      printf "    Logs       tail -f %s/termbot.log\n" "$LOG_DIR" >&2
      printf "    Restart    launchctl kickstart -k gui/\$(id -u)/com.termbot.agent\n" >&2
      ;;
    linux)
      printf "    Status     systemctl --user status termbot\n" >&2
      printf "    Logs       journalctl --user -u termbot -f\n" >&2
      printf "    Restart    systemctl --user restart termbot\n" >&2
      ;;
  esac
  printf "    Upgrade    curl -sSL https://raw.githubusercontent.com/%s/main/install.sh | bash -s -- --upgrade\n" "$REPO" >&2
  printf "    Uninstall  curl -sSL https://raw.githubusercontent.com/%s/main/install.sh | bash -s -- --uninstall\n" "$REPO" >&2
  printf "\n" >&2

  printf "  ${DIM}Open Telegram or Slack and send a message to your bot!${NC}\n\n" >&2
}

# =============================================================================
# Argument parsing
# =============================================================================

show_help() {
  cat >&2 <<EOF

  ${BOLD}termbot installer${NC}

  ${BOLD}Usage${NC}
    install.sh                 Install termbot interactively
    install.sh --quick         Install with minimal prompts
    install.sh --upgrade       Upgrade to the latest version
    install.sh --uninstall     Remove termbot

  ${BOLD}Options${NC}
    --quick, -q        Skip inline help text during setup
    --upgrade, -u      Download latest binary, restart service (config untouched)
    --uninstall        Stop service, remove files (config preserved by default)
    --help, -h         Show this help

  ${BOLD}Examples${NC}
    # Fresh install via curl
    curl -sSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash

    # Upgrade
    curl -sSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --upgrade

    # Uninstall
    curl -sSL https://raw.githubusercontent.com/${REPO}/main/install.sh | bash -s -- --uninstall

EOF
}

parse_args() {
  while [ $# -gt 0 ]; do
    case "$1" in
      --quick|-q)     QUICK=true;     shift ;;
      --upgrade|-u)   UPGRADE=true;   shift ;;
      --uninstall|--remove) UNINSTALL=true; shift ;;
      --help|-h)      show_help; exit 0 ;;
      *)              error "Unknown option: $1"; show_help; exit 1 ;;
    esac
  done
}

# =============================================================================
# Entry point — wrapped in main() for curl|bash safety
# =============================================================================

main() {
  setup_colors
  parse_args "$@"

  if [ "$UNINSTALL" = true ]; then
    do_uninstall
    exit 0
  fi

  if [ "$UPGRADE" = true ]; then
    do_upgrade
    exit 0
  fi

  do_install
}

main "$@"
