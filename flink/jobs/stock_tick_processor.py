"""
Flink Streaming Job: Stock Tick Processor
==========================================
Consumes raw tick data from Kafka, applies:
  1. 10-second VWAP aggregation (via KeyedProcessFunction + event-time timers)
  2. Anomaly detection (price spike alerts → SNS via Kafka alerts topic)
  3. Enriched tick stream → S3 processed zone via Kafka S3 Sink Connector

Topology:
  Kafka source (raw-ticks)
    ├── VWAP aggregator (10s)  → Kafka sink (aggregated-ticks)
    ├── Anomaly detector       → Kafka sink (alerts)
    └── Pass-through enrichment → Kafka sink (enriched-ticks)

NOTE: All operators use STRING type (raw JSON) throughout to avoid PyFlink
MAP serialization issues.  Each function parses JSON internally.
VWAP aggregation uses KeyedProcessFunction with event-time timers (not
TumblingEventTimeWindows + AggregateFunction) because the Beam runner's
pickled_main_session issue causes AggregateFunction to silently fail.
"""

import os
from pyflink.datastream import StreamExecutionEnvironment
from pyflink.datastream.connectors.kafka import (
    KafkaSource,
    KafkaSink,
    KafkaRecordSerializationSchema,
    KafkaOffsetsInitializer,
)
from pyflink.datastream.connectors.base import DeliveryGuarantee
from pyflink.common import WatermarkStrategy, Types, Duration
from pyflink.common.serialization import SimpleStringSchema
from pyflink.datastream.functions import (
    KeyedProcessFunction,
    RuntimeContext,
)
from pyflink.datastream.state import ValueStateDescriptor
import json
import logging
from datetime import datetime, timezone

logging.basicConfig(level=logging.INFO)
LOG = logging.getLogger("StockTickProcessor")

# ── Environment Variables ────────────────────────────────────────────────────
KAFKA_BOOTSTRAP  = os.environ.get("KAFKA_BOOTSTRAP_SERVERS", "kafka:9092")
INPUT_TOPIC      = os.environ.get("KAFKA_INPUT_TOPIC",  "raw-ticks")
VWAP_TOPIC       = os.environ.get("KAFKA_VWAP_TOPIC",   "vwap-ticks")
ALERT_TOPIC      = os.environ.get("KAFKA_ALERT_TOPIC",  "alerts")
ENRICHED_TOPIC   = os.environ.get("KAFKA_ENRICHED_TOPIC", "enriched-ticks")
CONSUMER_GROUP   = os.environ.get("KAFKA_CONSUMER_GROUP", "flink-tick-processor")

# Anomaly detection thresholds
PRICE_SPIKE_PCT  = float(os.environ.get("PRICE_SPIKE_PCT",  "0.02"))   # 2% price move in 1 tick
VOLUME_SPIKE_MUL = float(os.environ.get("VOLUME_SPIKE_MUL", "5.0"))    # 5× average volume


# ─────────────────────────────────────────────────────────────────────────────
# 10-Second VWAP Aggregation (KeyedProcessFunction)
# ─────────────────────────────────────────────────────────────────────────────
# Uses a SINGLE Types.STRING() state variable containing a JSON blob.
# This avoids all Beam runner issues with Types.FLOAT():
#   - 32-bit float precision loss on millisecond timestamps
#   - Possible 0.0 / None conflation in the state backend
#   - Multiple state variable overhead
#
# IMPORTANT: All state operations happen BEFORE yield, and yield is always
# the LAST statement.  This guards against the Beam runner not fully
# iterating the generator after collecting yielded values.

VWAP_WINDOW_MS = 10_000  # 10 seconds


class VWAPAggregator(KeyedProcessFunction):
    """
    10-second VWAP windowed aggregation.

    Accumulates ticks per symbol into aligned 10s windows.  Emits a VWAP
    record when the next window's first tick arrives (window transition).
    The final window is emitted via on_timer when the event-time watermark
    advances past the window end.

    State is a single JSON string to avoid Beam runner float-precision issues.
    """

    def open(self, ctx: RuntimeContext):
        self.window_state = ctx.get_state(
            ValueStateDescriptor("vwap_window", Types.STRING())
        )
        self._tick_count = 0
        self._emit_count = 0
        LOG.info("[VWAPAggregator] open() called")

    def _align_window(self, ts_ms):
        start = ts_ms - (ts_ms % VWAP_WINDOW_MS)
        return start, start + VWAP_WINDOW_MS

    def _build_output(self, state):
        vwap = state["sum_pv"] / state["sum_vol"] if state["sum_vol"] > 0 else 0
        return json.dumps({
            "symbol":       state["symbol"],
            "window_start": datetime.fromtimestamp(
                state["window_start"] / 1000, tz=timezone.utc
            ).isoformat(),
            "window_end":   datetime.fromtimestamp(
                state["window_end"] / 1000, tz=timezone.utc
            ).isoformat(),
            "vwap":         round(vwap, 4),
            "high":         round(state["high"], 4),
            "low":          round(state["low"], 4),
            "total_volume": state["sum_vol"],
            "tick_count":   state["count"],
            "record_type":  "10s_vwap",
            "timestamp":    datetime.now(timezone.utc).isoformat(),
        })

    def process_element(self, value, ctx):
        self._tick_count += 1
        tick   = json.loads(value)
        price  = float(tick["price"])
        volume = int(tick["volume"])
        symbol = tick["symbol"]
        ts_ms  = int(
            datetime.fromisoformat(tick["timestamp"]).timestamp() * 1000
        )

        w_start, w_end = self._align_window(ts_ms)

        state_json = self.window_state.value()
        state = json.loads(state_json) if state_json else None

        # Collect output to yield AFTER all state updates
        output = None

        # Tick belongs to a new window → prepare emission of the completed window
        if state and state["window_start"] != w_start:
            output = self._build_output(state)
            state = None

        if state is None:
            state = {
                "symbol":       symbol,
                "window_start": w_start,
                "window_end":   w_end,
                "sum_pv":       price * volume,
                "sum_vol":      volume,
                "high":         price,
                "low":          price,
                "count":        1,
            }
            ctx.timer_service().register_event_time_timer(w_end)
        else:
            state["sum_pv"]  += price * volume
            state["sum_vol"] += volume
            state["high"]     = max(state["high"], price)
            state["low"]      = min(state["low"], price)
            state["count"]   += 1

        # All state updates BEFORE yield
        self.window_state.update(json.dumps(state))

        if self._tick_count <= 5 or self._tick_count % 50 == 0:
            LOG.info(
                "[VWAPAggregator] tick #%d symbol=%s w_start=%d "
                "state_count=%d emit=%s",
                self._tick_count, symbol, w_start,
                state["count"], "YES" if output else "no",
            )

        # Yield LAST — after all state operations are complete
        if output is not None:
            self._emit_count += 1
            LOG.info(
                "[VWAPAggregator] EMIT #%d symbol=%s tick_count=%s",
                self._emit_count,
                json.loads(output)["symbol"],
                json.loads(output)["tick_count"],
            )
            yield output

    def on_timer(self, timestamp, ctx):
        state_json = self.window_state.value()
        if state_json:
            state = json.loads(state_json)
            if state["window_end"] <= timestamp:
                output = self._build_output(state)
                # Clear state BEFORE yield
                self.window_state.clear()
                self._emit_count += 1
                LOG.info(
                    "[VWAPAggregator] TIMER EMIT #%d symbol=%s tick_count=%d",
                    self._emit_count, state["symbol"], state["count"],
                )
                yield output


# ─────────────────────────────────────────────────────────────────────────────
# Anomaly Detection — Price Spike
# ─────────────────────────────────────────────────────────────────────────────

class PriceSpikeDetector(KeyedProcessFunction):
    """
    Stateful per-symbol price spike detector.
    Emits a JSON alert string if price changes by more than PRICE_SPIKE_PCT
    in one tick, or volume exceeds VOLUME_SPIKE_MUL × moving average.

    Input:  JSON string (raw tick)
    Output: JSON string (alert record)
    """

    def open(self, ctx: RuntimeContext):
        self.last_price_state = ctx.get_state(
            ValueStateDescriptor("last_price", Types.FLOAT())
        )
        self.avg_volume_state = ctx.get_state(
            ValueStateDescriptor("avg_volume", Types.FLOAT())
        )

    def process_element(self, value, ctx):
        tick    = json.loads(value) if isinstance(value, str) else value
        price   = float(tick["price"])
        volume  = int(tick["volume"])

        last_price  = self.last_price_state.value()
        avg_volume  = self.avg_volume_state.value() or float(volume)

        alerts = []

        # Price spike detection
        if last_price is not None:
            pct_change = abs(price - last_price) / last_price
            if pct_change >= PRICE_SPIKE_PCT:
                alerts.append({
                    "alert_type":  "PRICE_SPIKE",
                    "symbol":      tick["symbol"],
                    "timestamp":   tick["timestamp"],
                    "prev_price":  round(last_price, 4),
                    "curr_price":  round(price, 4),
                    "pct_change":  round(pct_change * 100, 4),
                    "threshold":   PRICE_SPIKE_PCT * 100,
                    "severity":    "HIGH" if pct_change >= PRICE_SPIKE_PCT * 2 else "MEDIUM",
                })

        # Volume spike detection
        volume_ratio = volume / avg_volume if avg_volume > 0 else 1.0
        if volume_ratio >= VOLUME_SPIKE_MUL:
            alerts.append({
                "alert_type":   "VOLUME_SPIKE",
                "symbol":       tick["symbol"],
                "timestamp":    tick["timestamp"],
                "curr_volume":  volume,
                "avg_volume":   round(avg_volume, 0),
                "volume_ratio": round(volume_ratio, 2),
                "threshold":    VOLUME_SPIKE_MUL,
                "severity":     "MEDIUM",
            })

        # Yield alerts as JSON strings
        for alert in alerts:
            yield json.dumps(alert)

        # Update state
        self.last_price_state.update(price)
        # Exponential moving average for volume (α = 0.1)
        new_avg = 0.9 * avg_volume + 0.1 * volume
        self.avg_volume_state.update(new_avg)


# ─────────────────────────────────────────────────────────────────────────────
# Tick Enrichment
# ─────────────────────────────────────────────────────────────────────────────

def enrich_tick(raw: str) -> str:
    """
    Parse raw tick JSON, add derived fields, return enriched JSON string.
    - mid_price: midpoint of bid/ask
    - spread_bps: spread as basis points
    - record_type tag
    """
    tick     = json.loads(raw)
    price    = float(tick["price"])
    bid      = float(tick.get("bid", price))
    ask      = float(tick.get("ask", price))
    mid      = (bid + ask) / 2
    spread   = ask - bid
    spread_bps = (spread / mid * 10000) if mid > 0 else 0

    enriched = {
        **tick,
        "mid_price":   round(mid, 4),
        "spread_bps":  round(spread_bps, 4),
        "record_type": "enriched_tick",
        "ingested_at": datetime.now(timezone.utc).isoformat(),
    }
    return json.dumps(enriched)


# ─────────────────────────────────────────────────────────────────────────────
# Main Job
# ─────────────────────────────────────────────────────────────────────────────

def build_kafka_source() -> KafkaSource:
    return (
        KafkaSource.builder()
        .set_bootstrap_servers(KAFKA_BOOTSTRAP)
        .set_topics(INPUT_TOPIC)
        .set_group_id(CONSUMER_GROUP)
        .set_starting_offsets(KafkaOffsetsInitializer.earliest())
        .set_value_only_deserializer(SimpleStringSchema())
        .build()
    )


def build_kafka_sink(topic: str) -> KafkaSink:
    return (
        KafkaSink.builder()
        .set_bootstrap_servers(KAFKA_BOOTSTRAP)
        .set_delivery_guarantee(DeliveryGuarantee.NONE)
        .set_record_serializer(
            KafkaRecordSerializationSchema.builder()
            .set_topic(topic)
            .set_value_serialization_schema(SimpleStringSchema())
            .build()
        )
        .build()
    )


def main():
    env = StreamExecutionEnvironment.get_execution_environment()
    env.set_parallelism(1)  # single TaskManager for portfolio project

    # ── Source ────────────────────────────────────────────────────────────────
    # raw_stream is STRING type (from SimpleStringSchema — no MAP conversion)
    raw_stream = env.from_source(
        source=build_kafka_source(),
        watermark_strategy=WatermarkStrategy
            .for_bounded_out_of_orderness(Duration.of_seconds(5))
            .with_idleness(Duration.of_seconds(10))
            .with_timestamp_assigner(
                lambda tick_str, _: int(
                    datetime.fromisoformat(
                        json.loads(tick_str)["timestamp"]
                    ).timestamp() * 1000
                )
            ),
        source_name="KafkaRawTicks",
    )

    # ── Branch 1: Enriched tick pass-through → enriched-ticks ────────────────
    enriched_stream = raw_stream.map(enrich_tick, output_type=Types.STRING())
    enriched_stream.sink_to(build_kafka_sink(ENRICHED_TOPIC))

    # ── Branch 2: 10-second VWAP aggregation → vwap-ticks ────────────────
    vwap_stream = (
        raw_stream
        .key_by(lambda raw: json.loads(raw)["symbol"])
        .process(VWAPAggregator(), output_type=Types.STRING())
    )
    vwap_stream.sink_to(build_kafka_sink(VWAP_TOPIC))

    # ── Branch 3: Anomaly / Alert detection ──────────────────────────────────
    alert_stream = (
        raw_stream
        .key_by(lambda raw: json.loads(raw)["symbol"])
        .process(PriceSpikeDetector(), output_type=Types.STRING())
    )
    alert_stream.sink_to(build_kafka_sink(ALERT_TOPIC))

    env.execute("StockTickProcessor")


if __name__ == "__main__":
    main()
