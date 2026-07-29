#!/usr/bin/env bash
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
APP_NAME=${APP_NAME:-Nodaystypst}
APP="$ROOT/${APP_NAME}.app"

cd "$ROOT"
MENU_BAR_APP=1 "$ROOT/Scripts/package_app.sh" debug
open "$APP"

echo "Launched $APP"
