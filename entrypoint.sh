#!/usr/bin/env bash
# Launch the plumber web service and the Shiny frontend side by side.
# If either process exits, the container stops.
set -euo pipefail

cd /app

echo "[entrypoint] starting plumber API on port ${NEUROIMAGING_API_PORT:-8000} ..."
Rscript run_api.R &
API_PID=$!

# Give the API a moment to bind before the app tries to reach it.
sleep 5

echo "[entrypoint] starting Shiny app on port ${NEUROIMAGING_APP_PORT:-3838} ..."
Rscript run_app.R &
APP_PID=$!

# Forward SIGTERM/SIGINT to both children for clean shutdown.
term() {
  echo "[entrypoint] shutting down ..."
  kill -TERM "$API_PID" "$APP_PID" 2>/dev/null || true
  wait
}
trap term SIGTERM SIGINT

# Exit as soon as either process dies.
wait -n "$API_PID" "$APP_PID"
echo "[entrypoint] a process exited; stopping container."
term
