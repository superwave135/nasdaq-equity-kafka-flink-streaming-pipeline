"""
Glue ETL Job: Streaming Data Curated Layer Builder
====================================================
Event-Triggered by user.

Reads enriched tick data and alerts from S3 processed zone,
builds a dimensional model in the S3 curated zone, and updates the
Glue Data Catalog for Athena querying.

Output tables:
  - fact_tick_events      : Individual enriched ticks (partitioned by date/symbol)
  - dim_symbols           : Symbol reference dimension
  - agg_daily_summary     : Daily price/volume summary per symbol
  - agg_alerts            : All anomaly alerts triggered during the session
"""

import sys
from datetime import datetime, timezone

from awsglue.context import GlueContext
from awsglue.job import Job
from awsglue.utils import getResolvedOptions
from pyspark.context import SparkContext
from pyspark.sql import DataFrame
from pyspark.sql import functions as F
from pyspark.sql.types import (
    StructType, StructField,
    StringType, DoubleType, LongType,
)

# ── Args ──────────────────────────────────────────────────────────────────────
args = getResolvedOptions(sys.argv, [
    "JOB_NAME",
    "S3_PROCESSED_BUCKET",
    "S3_CURATED_BUCKET",
    "GLUE_DATABASE",
    "PROCESSING_DATE",          # YYYY-MM-DD, injected by Lambda trigger
])

# ── Glue Context ──────────────────────────────────────────────────────────────
sc     = SparkContext()
glue   = GlueContext(sc)
spark  = glue.spark_session
job    = Job(glue)
job.init(args["JOB_NAME"], args)

PROCESSED_BUCKET = args["S3_PROCESSED_BUCKET"]
CURATED_BUCKET   = args["S3_CURATED_BUCKET"]
GLUE_DATABASE    = args["GLUE_DATABASE"]
PROCESSING_DATE  = args["PROCESSING_DATE"]

print(f"[INFO] Starting Glue ETL for date: {PROCESSING_DATE}")


# ─────────────────────────────────────────────────────────────────────────────
# Schemas
# ─────────────────────────────────────────────────────────────────────────────

ENRICHED_TICK_SCHEMA = StructType([
    StructField("symbol",      StringType(),    False),
    StructField("timestamp",   StringType(),    False),
    StructField("price",       DoubleType(),    False),
    StructField("volume",      LongType(),      False),
    StructField("bid",         DoubleType(),    True),
    StructField("ask",         DoubleType(),    True),
    StructField("spread",      DoubleType(),    True),
    StructField("mid_price",   DoubleType(),    True),
    StructField("spread_bps",  DoubleType(),    True),
    StructField("source",      StringType(),    True),
    StructField("ingested_at", StringType(),    True),
    StructField("record_type", StringType(),    True),
])

ALERT_SCHEMA = StructType([
    StructField("alert_type",   StringType(),  False),
    StructField("symbol",       StringType(),  False),
    StructField("timestamp",    StringType(),  False),
    StructField("severity",     StringType(),  True),
    StructField("pct_change",   DoubleType(),  True),
    StructField("prev_price",   DoubleType(),  True),
    StructField("curr_price",   DoubleType(),  True),
    StructField("curr_volume",  LongType(),    True),
    StructField("avg_volume",   DoubleType(),  True),
    StructField("volume_ratio", DoubleType(),  True),
    StructField("threshold",    DoubleType(),  True),
])

VWAP_SCHEMA = StructType([
    StructField("symbol",       StringType(),  False),
    StructField("timestamp",    StringType(),  False),
    StructField("window_start", StringType(),  True),
    StructField("window_end",   StringType(),  True),
    StructField("vwap",         DoubleType(),  True),
    StructField("high",         DoubleType(),  True),
    StructField("low",          DoubleType(),  True),
    StructField("total_volume", LongType(),    True),
    StructField("tick_count",   LongType(),    True),
    StructField("record_type",  StringType(),  True),
])


# ─────────────────────────────────────────────────────────────────────────────
# Read Processed Zone
# ─────────────────────────────────────────────────────────────────────────────

def read_json_safe(path: str, schema: StructType) -> DataFrame:
    """Read JSON from S3 path.  Returns empty DataFrame if path missing."""
    try:
        df = spark.read.schema(schema).json(path)
        # Force evaluation to detect missing path early
        _ = df.head(1)
        return df
    except Exception as e:
        print(f"[WARN] Path not found or empty: {path} ({e})")
        return spark.createDataFrame([], schema)


enriched_ticks = read_json_safe(
    f"s3://{PROCESSED_BUCKET}/enriched-ticks/date={PROCESSING_DATE}/",
    ENRICHED_TICK_SCHEMA,
)

alerts = read_json_safe(
    f"s3://{PROCESSED_BUCKET}/alerts/date={PROCESSING_DATE}/",
    ALERT_SCHEMA,
)

vwap_ticks = read_json_safe(
    f"s3://{PROCESSED_BUCKET}/vwap-ticks/date={PROCESSING_DATE}/",
    VWAP_SCHEMA,
)

enriched_count = enriched_ticks.count()
alert_count    = alerts.count()
vwap_count     = vwap_ticks.count()

print(f"[INFO] Enriched ticks: {enriched_count:,}")
print(f"[INFO] Alerts:         {alert_count:,}")
print(f"[INFO] VWAP records:   {vwap_count:,}")

if enriched_count == 0:
    print("[WARN] No enriched tick data found — writing dim_symbols only")
    # Still write dim_symbols so the catalog is populated


# ─────────────────────────────────────────────────────────────────────────────
# Dim: Symbols  (always written regardless of data)
# ─────────────────────────────────────────────────────────────────────────────

dim_symbols = spark.createDataFrame([
    ("AAPL",  "Apple Inc.",            "Technology",    "NASDAQ", "USD"),
    ("MSFT",  "Microsoft Corporation", "Technology",    "NASDAQ", "USD"),
    ("GOOGL", "Alphabet Inc.",         "Technology",    "NASDAQ", "USD"),
    ("AMZN",  "Amazon.com Inc.",       "Consumer",      "NASDAQ", "USD"),
    ("NVDA",  "NVIDIA Corporation",    "Semiconductor", "NASDAQ", "USD"),
], ["symbol", "company_name", "sector", "exchange", "currency"])

(
    dim_symbols.write
    .mode("overwrite")
    .parquet(f"s3://{CURATED_BUCKET}/dim_symbols/")
)
print("[INFO] Written: dim_symbols")


# ── Skip remaining tables if no enriched tick data ───────────────────────────
if enriched_count == 0 and alert_count == 0:
    print("[WARN] No streaming data found — skipping fact/agg tables")
    print(f"[INFO] Glue ETL complete for {PROCESSING_DATE}")
    job.commit()
    sys.exit(0)


# ─────────────────────────────────────────────────────────────────────────────
# Fact: Tick Events
# ─────────────────────────────────────────────────────────────────────────────

if enriched_count > 0:
    fact_tick_events = (
        enriched_ticks
        .withColumn("event_timestamp", F.to_timestamp("timestamp"))
        .withColumn("trade_date",      F.to_date("timestamp"))
        .withColumn("trade_hour",      F.hour("event_timestamp"))
        .withColumn("trade_minute",    F.minute("event_timestamp"))
        .withColumn("price_usd",       F.round("price", 4))
        .withColumn("mid_price_usd",   F.round("mid_price", 4))
        .select(
            "symbol", "event_timestamp", "trade_date", "trade_hour", "trade_minute",
            "price_usd", "volume", "bid", "ask", "mid_price_usd",
            "spread", "spread_bps", "source",
        )
    )

    (
        fact_tick_events.write
        .mode("overwrite")
        .partitionBy("trade_date", "symbol")
        .parquet(f"s3://{CURATED_BUCKET}/fact_tick_events/")
    )
    print("[INFO] Written: fact_tick_events")

    # ─────────────────────────────────────────────────────────────────────────
    # Agg: Daily Summary per Symbol
    # ─────────────────────────────────────────────────────────────────────────

    agg_daily_summary = (
        fact_tick_events
        .groupBy("trade_date", "symbol")
        .agg(
            F.first("price_usd").alias("open_price"),
            F.max("price_usd").alias("high_price"),
            F.min("price_usd").alias("low_price"),
            F.last("price_usd").alias("close_price"),
            F.sum("volume").alias("total_volume"),
            F.avg("price_usd").alias("avg_price"),
            F.avg("spread_bps").alias("avg_spread_bps"),
            F.count("*").alias("tick_count"),
        )
        .withColumn("price_range",      F.round(F.col("high_price") - F.col("low_price"), 4))
        .withColumn("price_range_pct",  F.round(F.col("price_range") / F.col("open_price") * 100, 4))
        .withColumn("session_return",   F.round((F.col("close_price") - F.col("open_price")) / F.col("open_price") * 100, 4))
        .withColumn("processed_at",     F.lit(datetime.now(timezone.utc).isoformat()))
    )

    (
        agg_daily_summary.write
        .mode("overwrite")
        .partitionBy("trade_date")
        .parquet(f"s3://{CURATED_BUCKET}/agg_daily_summary/")
    )
    print("[INFO] Written: agg_daily_summary")
else:
    print("[WARN] Skipping fact_tick_events and agg_daily_summary (no enriched data)")


# ─────────────────────────────────────────────────────────────────────────────
# Fact: VWAP (10-second Volume Weighted Average Price)
# ─────────────────────────────────────────────────────────────────────────────

if vwap_count > 0:
    fact_vwap = (
        vwap_ticks
        .withColumn("window_start_ts", F.to_timestamp("window_start"))
        .withColumn("window_end_ts",   F.to_timestamp("window_end"))
        .withColumn("trade_date",      F.to_date("timestamp"))
        .withColumn("vwap_usd",        F.round("vwap", 4))
        .withColumn("high_usd",        F.round("high", 4))
        .withColumn("low_usd",         F.round("low", 4))
        .withColumn("processed_at",    F.lit(datetime.now(timezone.utc).isoformat()))
        .select(
            "symbol", "trade_date", "window_start_ts", "window_end_ts",
            "vwap_usd", "high_usd", "low_usd", "total_volume", "tick_count",
            "processed_at",
        )
    )

    (
        fact_vwap.write
        .mode("overwrite")
        .partitionBy("trade_date", "symbol")
        .parquet(f"s3://{CURATED_BUCKET}/fact_vwap/")
    )
    print("[INFO] Written: fact_vwap")
else:
    print("[WARN] Skipping fact_vwap (no VWAP data)")


# ─────────────────────────────────────────────────────────────────────────────
# Agg: Alerts
# ─────────────────────────────────────────────────────────────────────────────

if alert_count > 0:
    agg_alerts = (
        alerts
        .withColumn("alert_timestamp", F.to_timestamp("timestamp"))
        .withColumn("trade_date",      F.to_date("timestamp"))
        .withColumn("processed_at",    F.lit(datetime.now(timezone.utc).isoformat()))
        .select(
            "trade_date", "alert_timestamp", "symbol",
            "alert_type", "severity", "threshold",
            "prev_price", "curr_price", "pct_change",
            "curr_volume", "avg_volume", "volume_ratio",
            "processed_at",
        )
    )

    (
        agg_alerts.write
        .mode("overwrite")
        .partitionBy("trade_date")
        .parquet(f"s3://{CURATED_BUCKET}/agg_alerts/")
    )
    print("[INFO] Written: agg_alerts")
else:
    print("[WARN] Skipping agg_alerts (no alert data)")


print(f"[INFO] Glue ETL complete for {PROCESSING_DATE}")
job.commit()
