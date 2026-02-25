#!/bin/bash
set -e

# ── Start Flink JobManager in the background ─────────────────────────────
# Pass through all args (e.g. "jobmanager") to the base image entrypoint
/docker-entrypoint.sh "$@" &
FLINK_PID=$!

# ── Wait for REST API to become ready ────────────────────────────────────
echo "[ENTRYPOINT] Waiting for Flink REST API on port 8081..."
for i in $(seq 1 60); do
  if curl -sf http://localhost:8081/overview > /dev/null 2>&1; then
    echo "[ENTRYPOINT] Flink REST API is ready."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[ENTRYPOINT] ERROR: Flink REST API not ready after 120s"
  fi
  sleep 2
done

# ── Submit PyFlink stock tick processor job ───────────────────────────────
echo "[ENTRYPOINT] Submitting PyFlink stock tick processor..."
/opt/flink/bin/flink run \
  -m localhost:8081 \
  -d \
  -py /opt/flink/jobs/stock_tick_processor.py || {
    echo "[ENTRYPOINT] WARNING: Job submission failed (exit code $?)"
}

echo "[ENTRYPOINT] Job submitted — keeping JobManager running."

# ── Foreground the JobManager process ────────────────────────────────────
wait $FLINK_PID
