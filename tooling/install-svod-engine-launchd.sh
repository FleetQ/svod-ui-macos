#!/usr/bin/env bash
# Install the dev.svod.engine launchd user agent so the Svod engine auto-starts at
# login (and on crash), and the app's "Start Svod" button works
# (it runs `launchctl kickstart -k gui/$UID/dev.svod.engine` then polls /ready).
#
# Points at the source installDist build. Re-run after `./gradlew installDist`
# (the launcher path is stable unless you `gradle clean`).
set -euo pipefail

ENGINE_DIR="${SVOD_ENGINE_DIR:-$HOME/htdocs/svod/engine}"
LAUNCHER="$ENGINE_DIR/build/install/svod-engine/bin/svod-engine"
CONFIG="${SVOD_CONFIG:-$HOME/htdocs/svod/dist/config.local.multivault.json}"
JAVA_HOME_DIR="$(/usr/libexec/java_home -v 20)"
LABEL="dev.svod.engine"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOGDIR="$HOME/Library/Logs/svod"

[ -x "$LAUNCHER" ] || { echo "ERROR: launcher not found at $LAUNCHER — run: (cd $ENGINE_DIR && JAVA_HOME=$JAVA_HOME_DIR ./gradlew installDist)"; exit 1; }
[ -f "$CONFIG" ]   || { echo "ERROR: config not found at $CONFIG"; exit 1; }
APPSUP="$HOME/Library/Application Support/Svod"
WRAPPER="$APPSUP/run-engine.sh"
mkdir -p "$LOGDIR" "$HOME/Library/LaunchAgents" "$APPSUP"

# Stop any current engine: the launchd agent (if installed) and a stray manual JVM
# (both would hold the vault lock / port 7619).
launchctl bootout "gui/$(id -u)/$LABEL" 2>/dev/null || true
pkill -f "dev.svod.engine.MainKt" 2>/dev/null || true
sleep 2

# Wrapper: passes the config explicitly (avoids launchd arg-forwarding quirks with the
# gradle launcher) and clears stale git/vault locks left by an unclean kill, so a
# KeepAlive restart after a crash doesn't loop on a leftover .git/index.lock.
# Call java directly (the gradle launcher script doesn't forward its arg reliably
# under launchd's minimal env → the engine fell back to a default config and crashed
# with "vaultPath required"). Also clear stale git locks so KeepAlive restarts after a
# crash don't loop on a leftover .git/index.lock.
cat > "$WRAPPER" <<WRAP
#!/bin/bash
export JAVA_HOME="$JAVA_HOME_DIR"
rm -f "\$HOME/Svod/"*/.git/index.lock 2>/dev/null || true
exec "$JAVA_HOME_DIR/bin/java" -cp "$ENGINE_DIR/build/install/svod-engine/lib/*" dev.svod.engine.MainKt "$CONFIG"
WRAP
chmod +x "$WRAPPER"

cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$WRAPPER</string>
  </array>
  <key>EnvironmentVariables</key><dict>
    <key>JAVA_HOME</key><string>$JAVA_HOME_DIR</string>
  </dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Background</string>
  <key>ThrottleInterval</key><integer>5</integer>
  <key>StandardOutPath</key><string>$LOGDIR/engine.out.log</string>
  <key>StandardErrorPath</key><string>$LOGDIR/engine.err.log</string>
</dict></plist>
PLIST

launchctl bootstrap "gui/$(id -u)" "$PLIST"
launchctl kickstart -k "gui/$(id -u)/$LABEL"
echo "Installed + started $LABEL"
echo "  launcher: $LAUNCHER"
echo "  config:   $CONFIG"
echo "  logs:     $LOGDIR/engine.{out,err}.log"
echo "Waiting for the App API on :7619…"
for i in $(seq 1 130); do
  if nc -z -w1 127.0.0.1 7619 2>/dev/null; then echo "engine up on :7619 after ${i}s ✓"; exit 0; fi
  sleep 1
done
echo "WARN: not up within 130s — check $LOGDIR/engine.err.log (model load can take longer on a cold start)"
