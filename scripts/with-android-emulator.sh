#!/usr/bin/env bash
# Runs a command with an Android device attached, starting an emulator when none is. A device
# already attached is used as it is. Otherwise the AVD is ANDROID_AVD, or the only one
# `emulator -list-avds` prints; with several and no ANDROID_AVD it stops and lists them. The
# emulator it starts runs headless, saves no snapshot, and is shut down when the command ends,
# so a run leaves an AVD as it found it.
# Usage: scripts/with-android-emulator.sh <command> [args...]
set -euo pipefail

BOOT_TIMEOUT=${ANDROID_BOOT_TIMEOUT:-240}

# The SDK's tools, from PATH or the SDK directory.
sdk_tool() {
  local name=$1 sub=$2 dir
  if command -v "$name" >/dev/null; then command -v "$name"; return; fi
  for dir in "${ANDROID_HOME:-}" "${ANDROID_SDK_ROOT:-}" "$HOME/Library/Android/sdk" "$HOME/Android/Sdk"; do
    if [ -n "$dir" ] && [ -x "$dir/$sub/$name" ]; then echo "$dir/$sub/$name"; return; fi
  done
  echo "with-android-emulator: $name not found; install the Android SDK or put it on PATH" >&2
  exit 1
}

adb=$(sdk_tool adb platform-tools)
if "$adb" devices | grep -q 'device$'; then
  exec "$@"
fi

emulator=$(sdk_tool emulator emulator)
avd=${ANDROID_AVD:-}
if [ -z "$avd" ]; then
  avds=$("$emulator" -list-avds | grep -v '^INFO')
  case $(printf '%s' "$avds" | grep -c .) in
    0) echo "with-android-emulator: no AVD; make one in Android Studio's Device Manager" >&2; exit 1 ;;
    1) avd=$avds ;;
    *) printf 'with-android-emulator: several AVDs; pick one with ANDROID_AVD=<name>:\n%s\n' "$avds" >&2; exit 1 ;;
  esac
fi

# A port of its own, so the serial is known and no other emulator is touched.
port=${ANDROID_EMULATOR_PORT:-5584}
serial="emulator-$port"
log=$(mktemp -t android-emulator.XXXXXX)
echo "with-android-emulator: starting $avd as $serial (log: $log)"
"$emulator" -avd "$avd" -port "$port" -no-window -no-snapshot-save -no-boot-anim >"$log" 2>&1 &
pid=$!

stop() {
  "$adb" -s "$serial" emu kill >/dev/null 2>&1 || true
  # Waits for it to exit, so the next run doesn't find it still attached.
  for _ in $(seq 1 30); do kill -0 "$pid" 2>/dev/null || return 0; sleep 1; done
  kill "$pid" 2>/dev/null || true
}
trap stop EXIT

deadline=$((SECONDS + BOOT_TIMEOUT))
until [ "$("$adb" -s "$serial" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = 1 ]; do
  if ! kill -0 "$pid" 2>/dev/null; then
    echo "with-android-emulator: the emulator exited while booting; its log:" >&2
    tail -20 "$log" >&2
    exit 1
  fi
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "with-android-emulator: $avd didn't boot in ${BOOT_TIMEOUT}s; its log: $log" >&2
    exit 1
  fi
  sleep 2
done
echo "with-android-emulator: $avd booted"

ANDROID_SERIAL=$serial "$@"