#!/bin/sh
set -eu

KAFKA_PORT="${ENVECTOR_AUDIT_KAFKA_PORT:-9092}"
KAFKA_TOPIC="${ENVECTOR_AUDIT_KAFKA_TOPIC:-envector.audit.events.v1}"

"$@" &
REDPANDA_PID=$!

cleanup() {
  kill -TERM "${REDPANDA_PID}" 2>/dev/null || true
}

trap cleanup INT TERM

attempts=30
i=1
while [ "${i}" -le "${attempts}" ]; do
  if rpk cluster info --brokers "localhost:${KAFKA_PORT}" >/dev/null 2>&1; then
    break
  fi
  sleep 2
  i=$((i + 1))
done

if [ "${i}" -gt "${attempts}" ]; then
  echo "Timed out waiting for Redpanda to accept Kafka connections" >&2
  wait "${REDPANDA_PID}"
  exit 1
fi

rpk topic create "${KAFKA_TOPIC}" --brokers "localhost:${KAFKA_PORT}" >/dev/null 2>&1 || true

wait "${REDPANDA_PID}"
