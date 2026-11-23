#!/usr/bin/env bash
set -e

ROOT="$(cd "$(dirname "$0")" && pwd)"
cd "$ROOT"

uvicorn farmacia_api:app --reload --app-dir api &
API_PID=$!

cleanup() {
    kill "$API_PID" 2>/dev/null || true
    adb reverse --remove tcp:8000 2>/dev/null || true
}

trap cleanup EXIT INT TERM

adb reverse tcp:8000 tcp:8000

cd app
flutter run --dart-define=API_BASE_URL=http://127.0.0.1:8000
