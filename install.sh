#!/usr/bin/env bash
# zcode-keysmith-custom — managed system-role entrypoint for the local ZCode App
# Installs: managed prompt, wrapper with injection toggle + channel skip,
#           LaunchAgent, /po slash command. macOS only.
# Usage:
#   ./install.sh --dry-run          preview only
#   ./install.sh --yes              install / update
#   ./install.sh --uninstall --yes  remove (files renamed to .bak_*, launchd env cleared)
set -euo pipefail

MANAGED_DIR="${KEYSMITH_MANAGED_DIR:-$HOME/.zcode-keysmith}"
REPO_DIR="$(cd "$(dirname "$0")" && pwd)"
ZCODE_APP="${ZCODE_APP_PATH:-/Applications/ZCode.app}"
RUNTIME="$ZCODE_APP/Contents/Resources/glm/zcode.cjs"
NODE_CMD="$ZCODE_APP/Contents/Frameworks/ZCode Helper.app/Contents/MacOS/ZCode Helper"
LAUNCH_AGENT="$HOME/Library/LaunchAgents/com.jia.zcode-keysmith.env.plist"
PLIST_LABEL="com.jia.zcode-keysmith.env"
ENV_SCRIPT="$MANAGED_DIR/bin/zcode-keysmith-env.sh"
ENV_KEYS=(ZCODE_AGENT_SERVER_COMMAND ZCODE_AGENT_SERVER_ARGS_JSON
          ZCODE_KEYSMITH_SYSTEM_FILE ZCODE_KEYSMITH_ORIGINAL
          ZCODE_KEYSMITH_NODE_COMMAND ZCODE_KEYSMITH_CACHE_DIR ZCODE_KEYSMITH_LOG_DIR)

APPLY=0; UNINSTALL=0
for arg in "$@"; do
  case "$arg" in
    --yes) APPLY=1 ;;
    --dry-run) APPLY=0 ;;
    --uninstall) UNINSTALL=1 ;;
    -h|--help) sed -n '2,9p' "$0"; exit 0 ;;
    *) echo "unknown arg: $arg"; exit 2 ;;
  esac
done

backup() { # backup <path>
  local p="$1"
  [ -e "$p" ] || return 0
  local stamp; stamp="$(date +%Y%m%d_%H%M%S)"
  mv "$p" "$p.bak_$stamp"
  echo "backup: $p -> $p.bak_$stamp"
}

write_file() { # write_file <path> <tmp-source>
  local dst="$1" src="$2"
  mkdir -p "$(dirname "$dst")"
  if [ "$APPLY" = 1 ]; then
    install -m "$( [ "${src%.py}" != "$src" ] && echo 755 || echo 644)" "$src" "$dst"
    echo "wrote: $dst"
  else
    echo "preview: would write $dst"
  fi
}

uninstall_all() {
  echo "== uninstall preview ==" 
  for f in "$MANAGED_DIR/system-role.md" "$MANAGED_DIR/skip-channels.txt" \
           "$MANAGED_DIR/config.json" "$MANAGED_DIR/bin/zcode-agent-wrapper.py" \
           "$ENV_SCRIPT" "$LAUNCH_AGENT"; do
    [ -e "$f" ] && echo "target: $f"
  done
  [ "$APPLY" = 1 ] || exit 0
  for f in "$MANAGED_DIR/system-role.md" "$MANAGED_DIR/skip-channels.txt" \
           "$MANAGED_DIR/config.json" "$MANAGED_DIR/bin/zcode-agent-wrapper.py" \
           "$ENV_SCRIPT" "$LAUNCH_AGENT"; do
    backup "$f"
  done
  for k in "${ENV_KEYS[@]}"; do launchctl unsetenv "$k" 2>/dev/null || true; done
  UID_NUM="$(id -u)"
  launchctl disable "gui/$UID_NUM/$PLIST_LABEL" 2>/dev/null || true
  launchctl bootout "gui/$UID_NUM/$PLIST_LABEL" 2>/dev/null || true
  echo "uninstall done (backups kept). Reopen ZCode for a clean runtime."
  exit 0
}

[ "$UNINSTALL" = 1 ] && uninstall_all

# --- preflight -------------------------------------------------------------
[ -f "$RUNTIME" ] || { echo "ZCode runtime not found: $RUNTIME"; echo "set ZCODE_APP_PATH and retry"; exit 1; }
[ -f "$NODE_CMD" ] || { echo "ZCode node helper not found: $NODE_CMD"; exit 1; }
rg -q 'customSystemPrompt' "$RUNTIME" || { echo "runtime entrypoint shape not recognized"; exit 1; }
SYSTEM_FILE_SRC="${KEYSMITH_SYSTEM_SOURCE:-$REPO_DIR/examples/zcode-unrestricted.md}"
[ -f "$SYSTEM_FILE_SRC" ] || { echo "missing source prompt: $SYSTEM_FILE_SRC"; exit 1; }

echo "== zcode-keysmith-custom install $([ "$APPLY" = 1 ] && echo '(apply)' || echo '(dry-run)') =="
echo "managed_dir: $MANAGED_DIR"
echo "zcode_app:   $ZCODE_APP"
echo "prompt src:  $SYSTEM_FILE_SRC"

STAMP="$(date +%Y%m%d_%H%M%S)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# --- 1. managed files --------------------------------------------------------
write_file "$MANAGED_DIR/system-role.md" "$SYSTEM_FILE_SRC"

cat > "$TMP/skip-channels.txt" <<'EOF'
# 不注入的通道关键词（一行一个，子串匹配，改完即生效无需重启）
# offpeak-idle-plan = 官方送的闲时算力通道
# bigmodel-start-plan = 官方送的体验通道
offpeak
start-plan
EOF
write_file "$MANAGED_DIR/skip-channels.txt" "$TMP/skip-channels.txt"

cat > "$TMP/wrapper.py" < "$REPO_DIR/bin/zcode-agent-wrapper.py"
write_file "$MANAGED_DIR/bin/zcode-agent-wrapper.py" "$TMP/wrapper.py"

# --- 2. config + env script + LaunchAgent ------------------------------------
cat > "$TMP/config.json" <<EOF
{
  "tool_version": "custom-1.0",
  "mode": "zcode-app-wrapper",
  "system_file": "$MANAGED_DIR/system-role.md",
  "wrapper": "$MANAGED_DIR/bin/zcode-agent-wrapper.py",
  "env_script": "$ENV_SCRIPT",
  "launch_agent": "$LAUNCH_AGENT",
  "zcode_runtime": "$RUNTIME",
  "node_command": "$NODE_CMD",
  "cache_dir": "$MANAGED_DIR/cache",
  "wrapper_log": "$MANAGED_DIR/logs/wrapper-start.jsonl"
}
EOF
write_file "$MANAGED_DIR/config.json" "$TMP/config.json"

cat > "$TMP/env.sh" <<EOF
#!/bin/sh
set -eu
launchctl setenv ZCODE_AGENT_SERVER_COMMAND '$MANAGED_DIR/bin/zcode-agent-wrapper.py'
launchctl setenv ZCODE_AGENT_SERVER_ARGS_JSON '["app-server","--stdio"]'
launchctl setenv ZCODE_KEYSMITH_SYSTEM_FILE '$MANAGED_DIR/system-role.md'
launchctl setenv ZCODE_KEYSMITH_ORIGINAL '$RUNTIME'
launchctl setenv ZCODE_KEYSMITH_NODE_COMMAND '$NODE_CMD'
launchctl setenv ZCODE_KEYSMITH_CACHE_DIR '$MANAGED_DIR/cache'
launchctl setenv ZCODE_KEYSMITH_LOG_DIR '$MANAGED_DIR/logs'
EOF
write_file "$ENV_SCRIPT" "$TMP/env.sh"

cat > "$TMP/agent.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>$PLIST_LABEL</string>
  <key>ProgramArguments</key>
  <array><string>/bin/sh</string><string>$ENV_SCRIPT</string></array>
  <key>RunAtLoad</key><true/>
  <key>StandardErrorPath</key><string>$MANAGED_DIR/logs/launchagent.err.log</string>
  <key>StandardOutPath</key><string>$MANAGED_DIR/logs/launchagent.out.log</string>
</dict>
</plist>
EOF
write_file "$LAUNCH_AGENT" "$TMP/agent.plist"

# --- 3. slash commands --------------------------------------------------------
write_file "$HOME/.zcode/commands/po.md" "$REPO_DIR/commands/po.md"
mkdir -p "$HOME/.zcode/cli/plugins/local/keysmith/commands"
write_file "$HOME/.zcode/cli/plugins/local/keysmith/commands/po.md" "$REPO_DIR/commands/keysmith-po.md"

if [ "$APPLY" != 1 ]; then
  echo
  echo "dry-run complete. rerun with --yes to apply."
  exit 0
fi

# --- 4. activate ---------------------------------------------------------------
mkdir -p "$MANAGED_DIR/logs" "$MANAGED_DIR/cache"
sh "$ENV_SCRIPT"
UID_NUM="$(id -u)"
launchctl enable "gui/$UID_NUM/$PLIST_LABEL" 2>/dev/null || true
launchctl bootout "gui/$UID_NUM/$PLIST_LABEL" 2>/dev/null || true
launchctl bootstrap "gui/$UID_NUM" "$LAUNCH_AGENT" 2>/dev/null || true

echo
echo "== verify =="
launchctl getenv ZCODE_AGENT_SERVER_COMMAND
python3 "$MANAGED_DIR/bin/zcode-agent-wrapper.py" status
echo
echo "done. fully quit ZCode (Cmd+Q) and reopen; injection starts on the next new task."
echo "toggle: /po on | /po off | /po status"
