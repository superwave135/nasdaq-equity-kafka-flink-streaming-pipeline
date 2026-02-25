#!/bin/bash
set -e

KAFKA_HOME="/opt/kafka"
CONFIG="$KAFKA_HOME/config/kraft/server.properties"
LOG_DIR="/var/kafka/data"
CLUSTER_ID="stock-streaming-pipeline-001"

# ── Override advertised.listeners if env var is set ──────────────────────
if [ -n "$KAFKA_ADVERTISED_LISTENERS" ]; then
  sed -i "s|^advertised.listeners=.*|advertised.listeners=${KAFKA_ADVERTISED_LISTENERS}|" "$CONFIG"
fi

# ── Format KRaft storage (idempotent — skip if already formatted) ────────
if [ ! -f "$LOG_DIR/meta.properties" ]; then
  echo "Formatting KRaft storage with cluster ID: $CLUSTER_ID"
  "$KAFKA_HOME/bin/kafka-storage.sh" format \
    --config "$CONFIG" \
    --cluster-id "$CLUSTER_ID" \
    --ignore-formatted
fi

# ── Start Kafka in the background ───────────────────────────────────────
"$KAFKA_HOME/bin/kafka-server-start.sh" "$CONFIG" &
KAFKA_PID=$!

# ── Wait for broker to be ready ─────────────────────────────────────────
echo "Waiting for Kafka broker to start..."
for i in $(seq 1 30); do
  if "$KAFKA_HOME/bin/kafka-broker-api-versions.sh" --bootstrap-server localhost:9092 > /dev/null 2>&1; then
    echo "Kafka broker is ready."
    break
  fi
  sleep 2
done

# ── Delete and recreate topics (clean slate each run) ────────────────────
# KAFKA_TOPICS env var format: "topic:partitions:replicas,topic:partitions:replicas"
if [ -n "$KAFKA_TOPICS" ]; then
  IFS=',' read -ra TOPICS <<< "$KAFKA_TOPICS"
  for topic_spec in "${TOPICS[@]}"; do
    IFS=':' read -r topic partitions replicas <<< "$topic_spec"
    # Delete existing topic to clear stale data from previous runs
    "$KAFKA_HOME/bin/kafka-topics.sh" \
      --bootstrap-server localhost:9092 \
      --delete --topic "$topic" 2>/dev/null || true
  done
  sleep 2
  for topic_spec in "${TOPICS[@]}"; do
    IFS=':' read -r topic partitions replicas <<< "$topic_spec"
    echo "Creating topic: $topic (partitions=$partitions, replicas=$replicas)"
    "$KAFKA_HOME/bin/kafka-topics.sh" \
      --bootstrap-server localhost:9092 \
      --create \
      --topic "$topic" \
      --partitions "$partitions" \
      --replication-factor "$replicas" || true
  done
fi

# ── Keep container running (foreground the broker) ──────────────────────
wait $KAFKA_PID
