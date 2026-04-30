#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"

APP_NAME="WyomingAppleSpeechServer"
BUNDLE_ID="io.homeassistant.WyomingAppleSpeechServer"
PROJECT_NAME="WyomingAppleSpeechServer.xcodeproj"
SCHEME_NAME="WyomingAppleSpeechServer"
DESTINATION="${DESTINATION:-platform=macOS}"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD_DIR="$ROOT_DIR/build/DerivedData-Script"
DIST_DIR="$ROOT_DIR/dist"
BUILT_APP="$BUILD_DIR/Build/Products/Debug/$APP_NAME.app"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/$APP_NAME"

XCODEBUILD_FLAGS=()
if [[ "${VERBOSE:-0}" != "1" ]]; then
  XCODEBUILD_FLAGS+=("-quiet")
fi

build_app() {
  echo "Building $APP_NAME..."
  xcodebuild \
    "${XCODEBUILD_FLAGS[@]}" \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$BUILD_DIR" \
    build

  rm -rf "$APP_BUNDLE"
  mkdir -p "$DIST_DIR"
  ditto "$BUILT_APP" "$APP_BUNDLE"
  echo "Built $APP_BUNDLE"
}

test_app() {
  echo "Testing $APP_NAME..."
  xcodebuild \
    "${XCODEBUILD_FLAGS[@]}" \
    -project "$ROOT_DIR/$PROJECT_NAME" \
    -scheme "$SCHEME_NAME" \
    -destination "$DESTINATION" \
    -derivedDataPath "$BUILD_DIR" \
    test
}

stop_app() {
  pkill -x "$APP_NAME" >/dev/null 2>&1 || true
}

open_app() {
  echo "Opening $APP_BUNDLE..."
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  build)
    build_app
    ;;
  run)
    stop_app
    build_app
    open_app
    ;;
  --debug|debug)
    stop_app
    build_app
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    stop_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    stop_app
    build_app
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    stop_app
    build_app
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  test)
    test_app
    ;;
  clean)
    rm -rf "$BUILD_DIR" "$APP_BUNDLE"
    ;;
  *)
    echo "usage: $0 [run|build|test|clean|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
