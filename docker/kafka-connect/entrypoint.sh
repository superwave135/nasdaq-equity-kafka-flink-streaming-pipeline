#!/bin/bash
set -e

# ── Wait for Kafka broker DNS to be resolvable ───────────────────────────
KAFKA_HOST="${CONNECT_BOOTSTRAP_SERVERS%%:*}"
echo "[ENTRYPOINT] Waiting for Kafka DNS ($KAFKA_HOST) to resolve..."
for i in $(seq 1 60); do
  if getent hosts "$KAFKA_HOST" > /dev/null 2>&1; then
    echo "[ENTRYPOINT] Kafka DNS resolved."
    break
  fi
  if [ "$i" -eq 60 ]; then
    echo "[ENTRYPOINT] WARNING: Kafka DNS not resolved after 120s, continuing anyway..."
  fi
  sleep 2
done

# ── Wait for Kafka broker port to be reachable ───────────────────────────
echo "[ENTRYPOINT] Waiting for Kafka broker ($CONNECT_BOOTSTRAP_SERVERS)..."
for i in $(seq 1 30); do
  if nc -z "$KAFKA_HOST" 9092 2>/dev/null; then
    echo "[ENTRYPOINT] Kafka broker is reachable."
    break
  fi
  if [ "$i" -eq 30 ]; then
    echo "[ENTRYPOINT] WARNING: Kafka broker not reachable after 60s, continuing anyway..."
  fi
  sleep 2
done

# ── Start the Kafka Connect worker in the background ─────────────────────
/etc/confluent/docker/run &
CONNECT_PID=$!

# ── Wait for REST API to become ready ────────────────────────────────────
echo "[ENTRYPOINT] Waiting for Kafka Connect REST API on port 8083..."
for i in $(seq 1 90); do
  if curl -sf http://localhost:8083/connectors > /dev/null 2>&1; then
    echo "[ENTRYPOINT] Kafka Connect REST API is ready."
    break
  fi
  if [ "$i" -eq 90 ]; then
    echo "[ENTRYPOINT] ERROR: Connect REST API not ready after 180s"
  fi
  sleep 2
done

# ── Register S3 Sink Connector (delete-then-create for config freshness) ──
echo "[ENTRYPOINT] Registering S3 sink connector..."
echo "[ENTRYPOINT]   S3_REGION=${S3_REGION}"
echo "[ENTRYPOINT]   S3_PROCESSED_BUCKET=${S3_PROCESSED_BUCKET}"

# Delete existing connector if present (stale config persists in Kafka internal topics)
DEL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X DELETE http://localhost:8083/connectors/s3-sink-enriched-ticks)
if [ "$DEL_CODE" = "204" ]; then
  echo "[ENTRYPOINT] Deleted existing connector (will re-create with fresh config)."
  sleep 2
fi

CONNECTOR_CONFIG=$(cat <<CEOF
{
  "name": "s3-sink-enriched-ticks",
  "config": {
    "connector.class": "io.confluent.connect.s3.S3SinkConnector",
    "tasks.max": "1",
    "topics": "enriched-ticks,vwap-ticks,alerts",
    "s3.region": "${S3_REGION}",
    "s3.bucket.name": "${S3_PROCESSED_BUCKET}",
    "s3.part.size": "5242880",
    "topics.dir": "",
    "store.kafka.keys": "false",
    "store.kafka.headers": "false",
    "partitioner.class": "io.confluent.connect.storage.partitioner.TimeBasedPartitioner",
    "path.format": "'date'=YYYY-MM-dd",
    "partition.duration.ms": "3600000",
    "locale": "en_US",
    "timezone": "UTC",
    "timestamp.extractor": "Record",
    "format.class": "io.confluent.connect.s3.format.json.JsonFormat",
    "storage.class": "io.confluent.connect.s3.storage.S3Storage",
    "flush.size": "5",
    "rotate.interval.ms": "10000",
    "rotate.schedule.interval.ms": "30000",
    "schemas.enable": "false",
    "schema.compatibility": "NONE",
    "errors.tolerance": "none",
    "errors.log.enable": "true",
    "errors.log.include.messages": "true",
    "key.converter": "org.apache.kafka.connect.storage.StringConverter",
    "value.converter": "org.apache.kafka.connect.json.JsonConverter",
    "value.converter.schemas.enable": "false",
    "consumer.override.isolation.level": "read_uncommitted"
  }
}
CEOF
)

RESPONSE=$(curl -s -w "\n%{http_code}" -X POST http://localhost:8083/connectors \
  -H "Content-Type: application/json" \
  -d "$CONNECTOR_CONFIG")

HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [ "$HTTP_CODE" = "201" ] || [ "$HTTP_CODE" = "200" ]; then
  echo "[ENTRYPOINT] S3 sink connector registered successfully (HTTP $HTTP_CODE)."
else
  echo "[ENTRYPOINT] WARNING: Connector registration returned HTTP $HTTP_CODE"
  echo "[ENTRYPOINT] Response: $BODY"
fi

# ── Foreground the Connect worker ────────────────────────────────────────
wait $CONNECT_PID
