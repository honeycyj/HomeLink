#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
if (( $# > 0 )); then shift; fi
TASK_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="HomeLink"
BUNDLE_ID="local.homelink.HomeLink"
BUILD_DIR="$TASK_ROOT/.build"
APP_BUNDLE="$BUILD_DIR/DerivedData/Build/Products/Debug/$APP_NAME.app"
mkdir -p "$BUILD_DIR"

# Xcode and CLI share the same private local signing configuration.
source "$TASK_ROOT/script/signing_settings.sh"

case "$MODE" in
  run|--verify|verify|--logs|logs|--telemetry|telemetry|--debug|debug) ;;
  *) echo "usage: $0 [run|--verify|--logs|--telemetry|--debug]" >&2; exit 2 ;;
esac

# Older builds launched ssh directly. Record only their own immediate SSH children;
# current builds use a lifeline supervisor that also handles unexpected parent death.
LEGACY_SSH_PIDS=()
while read -r app_pid; do
  while read -r child_pid; do
    if [[ "$(ps -p "$child_pid" -o comm=)" == "/usr/bin/ssh" ]]; then
      LEGACY_SSH_PIDS+=("$child_pid")
    fi
  done < <(pgrep -P "$app_pid" || true)
done < <(pgrep -x "$APP_NAME" || true)
pkill -x "$APP_NAME" >/dev/null 2>&1 || true
for _ in 1 2 3 4 5; do
  if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
  sleep 1
done
# A debugger can suspend termination; remove the old app before launching a new build.
if pgrep -x "$APP_NAME" >/dev/null; then
  pkill -KILL -x "$APP_NAME" >/dev/null 2>&1 || true
  for _ in 1 2 3 4 5; do
    if ! pgrep -x "$APP_NAME" >/dev/null; then break; fi
    sleep 1
  done
fi
if pgrep -x "$APP_NAME" >/dev/null; then
  echo 'Stop the HomeLink debug session in Xcode, then run again.' >&2
  exit 1
fi
if [[ -n "${LEGACY_SSH_PIDS[*]:-}" ]]; then
  for ssh_pid in "${LEGACY_SSH_PIDS[@]}"; do
    kill -TERM "$ssh_pid" >/dev/null 2>&1 || true
  done
fi
if ! xcodebuild -project "$TASK_ROOT/HomeLink.xcodeproj" -scheme HomeLink \
    -destination 'platform=macOS' -derivedDataPath "$BUILD_DIR/DerivedData" \
    "${SIGNING_SETTINGS[@]}" build >"$BUILD_DIR/build.log" 2>&1; then
  tail -n 70 "$BUILD_DIR/build.log" >&2
  exit 1
fi

case "$MODE" in
  --debug|debug) exec lldb -- "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "$@" ;;
  *) /usr/bin/open "$APP_BUNDLE" --args "$@" ;;
esac

case "$MODE" in
  --verify|verify)
    for _ in 1 2 3 4 5; do
      if [[ "$(pgrep -x "$APP_NAME" | wc -l | tr -d ' ')" == "1" ]]; then
        echo 'HomeLink: build and launch succeeded (menu-bar app; no Dock icon).'
        exit 0
      fi
      sleep 1
    done
    echo 'Build succeeded, but HomeLink did not remain running.' >&2
    exit 1
    ;;
  --logs|logs) exec /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\"" ;;
  --telemetry|telemetry) exec /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\"" ;;
esac
