"""
Pipeline Status Lambda
=======================
Called by API Gateway GET /pipeline/status
Polled by the dashboard every 2 seconds to update the live UI.

Returns:
  - Current run state (IDLE / STARTING / RUNNING / COMPLETED / STOPPED / FAILED)
  - Tick count progress (e.g. 34/60)
  - Last known price per symbol
  - Run timing metadata
"""

import json
import os
from datetime import datetime, timezone
from decimal import Decimal

import boto3

# ── Environment ───────────────────────────────────────────────────────────────
AWS_REGION     = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]

# ── Clients ───────────────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMODB_TABLE)

CORS = {
    "Content-Type":                "application/json",
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "GET,POST,DELETE,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type",
}


def decimal_to_float(obj):
    """JSON serialiser helper for DynamoDB Decimal types."""
    if isinstance(obj, Decimal):
        return float(obj)
    raise TypeError(f"Object of type {type(obj)} is not JSON serializable")


def lambda_handler(event, context):
    """
    GET /pipeline/status

    Returns the current pipeline run state for dashboard polling.
    Always returns 200 — a state of IDLE means no run is active.
    """
    # ── Fetch current run record ──────────────────────────────────────────────
    run_response  = table.get_item(Key={"pk": "CURRENT_RUN", "sk": "STATE"})
    run           = run_response.get("Item")

    if not run:
        return {
            "statusCode": 200,
            "body": json.dumps({
                "run_state":   "IDLE",
                "tick_count":  0,
                "total_ticks": 60,
                "last_prices": {},
                "run_id":      None,
                "started_at":  None,
                "updated_at":  None,
            }, default=decimal_to_float),
            "headers": CORS,
        }

    # ── Fetch current prices ──────────────────────────────────────────────────
    prices_response = table.query(
        KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq("PRICE_STATE"),
    )
    last_prices = {
        item["sk"]: float(item["last_price"])
        for item in prices_response.get("Items", [])
    }

    # ── Compute progress percentage ───────────────────────────────────────────
    tick_count  = int(run.get("tick_count",  0))
    total_ticks = int(run.get("total_ticks", 60))
    progress    = round((tick_count / total_ticks) * 100, 1) if total_ticks > 0 else 0

    # ── Compute elapsed seconds ───────────────────────────────────────────────
    elapsed_seconds = None
    if run.get("started_at"):
        try:
            started = datetime.fromisoformat(run["started_at"])
            elapsed_seconds = round(
                (datetime.now(timezone.utc) - started).total_seconds(), 1
            )
        except Exception:
            pass

    payload = {
        "run_id":          run.get("run_id"),
        "run_state":       run.get("run_state", "IDLE"),
        "tick_count":      tick_count,
        "total_ticks":     total_ticks,
        "progress_pct":    progress,
        "last_prices":     last_prices,
        "started_at":      run.get("started_at"),
        "updated_at":      run.get("updated_at"),
        "completed_at":    run.get("completed_at"),
        "elapsed_seconds": elapsed_seconds,
        "glue_run_id":     run.get("glue_run_id"),
        "error":           run.get("error"),
    }

    return {
        "statusCode": 200,
        "body": json.dumps(payload, default=decimal_to_float),
        "headers": CORS,
    }
