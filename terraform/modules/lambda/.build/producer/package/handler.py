"""
Stock Tick Producer Lambda — Self-Invoking Loop
================================================
Invoked by the Controller Lambda with {"run_id": "...", "tick_count": 0}.

Each invocation:
  1. Checks DynamoDB run_state — aborts if STOPPED/FAILED
  2. Reads last prices from DynamoDB (price continuity via GBM)
  3. Generates 5 tick records and publishes to Kafka
  4. Increments tick_count in DynamoDB
  5. If tick_count < TOTAL_TICKS: sleeps 1s, invokes self (async)
  6. If tick_count >= TOTAL_TICKS: invokes Teardown Lambda (async)

The 1-second sleep happens INSIDE the Lambda execution before the
async self-invocation — this gives ~1s cadence without EventBridge.
Lambda timeout is set to 10s in Terraform to cover the sleep + work.
"""

import json
import math
import os
import random
import time
from datetime import datetime, timezone
from decimal import Decimal

import boto3
from kafka import KafkaProducer
from kafka.errors import KafkaError

# ── Environment ───────────────────────────────────────────────────────────────
AWS_REGION           = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")
KAFKA_BOOTSTRAP      = os.environ["KAFKA_BOOTSTRAP_SERVERS"]
KAFKA_TOPIC          = os.environ.get("KAFKA_TOPIC", "raw-ticks")
DYNAMODB_TABLE       = os.environ["DYNAMODB_TABLE"]
PRODUCER_LAMBDA_ARN  = os.environ.get("PRODUCER_LAMBDA_ARN", "")  # resolved at runtime via context
TEARDOWN_LAMBDA_ARN  = os.environ["TEARDOWN_LAMBDA_ARN"]
TOTAL_TICKS          = int(os.environ.get("TOTAL_TICKS", "60"))
TICK_INTERVAL_S      = float(os.environ.get("TICK_INTERVAL_S", "1.0"))

# ── Stock Universe ────────────────────────────────────────────────────────────
STOCKS = {
    "AAPL":  {"base_price": 182.00, "volatility": 0.25, "drift": 0.08},
    "MSFT":  {"base_price": 415.00, "volatility": 0.22, "drift": 0.10},
    "GOOGL": {"base_price": 175.00, "volatility": 0.28, "drift": 0.09},
    "AMZN":  {"base_price": 195.00, "volatility": 0.30, "drift": 0.12},
    "NVDA":  {"base_price": 875.00, "volatility": 0.45, "drift": 0.15},
}

# ── Clients ───────────────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMODB_TABLE)
lambda_  = boto3.client("lambda", region_name=AWS_REGION)


# ─────────────────────────────────────────────────────────────────────────────
# Price Simulation (GBM)
# ─────────────────────────────────────────────────────────────────────────────

def gbm_next_price(current_price, volatility, drift, dt=1/252/6.5/3600):
    """
    Geometric Brownian Motion — one tick step.
    dS = S * exp((mu - sigma^2/2)*dt + sigma*sqrt(dt)*Z) where Z ~ N(0,1)
    dt = 1 second as a fraction of a trading year.
    """
    Z = random.gauss(0, 1)
    return current_price * math.exp(
        (drift - 0.5 * volatility ** 2) * dt + volatility * math.sqrt(dt) * Z
    )


def simulate_volume(price):
    base   = max(100, int(random.lognormvariate(6, 1)))
    factor = max(0.5, 1000 / price)
    return int(base * factor / 100) * 100


def simulate_spread(price):
    return round(price * random.uniform(0.0001, 0.0005), 4)


def build_tick(symbol, price):
    spread = simulate_spread(price)
    return {
        "symbol":    symbol,
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "price":     round(price, 4),
        "volume":    simulate_volume(price),
        "bid":       round(price - spread / 2, 4),
        "ask":       round(price + spread / 2, 4),
        "spread":    round(spread, 4),
        "source":    "simulator",
    }


# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB State
# ─────────────────────────────────────────────────────────────────────────────

def get_run_state(run_id):
    """Fetch the current run record."""
    response = table.get_item(Key={"pk": "CURRENT_RUN", "sk": "STATE"})
    item = response.get("Item")
    if item and item.get("run_id") == run_id:
        return item
    return None


def get_last_prices():
    """Fetch persisted prices, fall back to base prices for missing symbols."""
    prices = {}
    try:
        response = table.query(
            KeyConditionExpression=boto3.dynamodb.conditions.Key("pk").eq("PRICE_STATE"),
        )
        for item in response.get("Items", []):
            prices[item["sk"]] = float(item["last_price"])
    except Exception as e:
        print(f"[WARN] Price read failed: {e}")

    for symbol, params in STOCKS.items():
        prices.setdefault(symbol, params["base_price"])
    return prices


def save_prices_and_increment(run_id, next_prices, new_tick_count):
    """Save updated prices and increment tick_count on the run record."""
    now = datetime.now(timezone.utc).isoformat()

    with table.batch_writer() as batch:
        for symbol, price in next_prices.items():
            batch.put_item(Item={
                "pk":         "PRICE_STATE",
                "sk":         symbol,
                "last_price": Decimal(str(round(price, 4))),
                "updated_at": now,
            })

    price_snapshot = {s: str(round(p, 4)) for s, p in next_prices.items()}
    table.update_item(
        Key={"pk": "CURRENT_RUN", "sk": "STATE"},
        UpdateExpression="SET tick_count = :tc, updated_at = :ua, last_prices = :lp",
        ExpressionAttributeValues={
            ":tc": new_tick_count,
            ":ua": now,
            ":lp": price_snapshot,
        },
    )


# ─────────────────────────────────────────────────────────────────────────────
# Kafka
# ─────────────────────────────────────────────────────────────────────────────

def publish_ticks(ticks):
    producer = KafkaProducer(
        bootstrap_servers=KAFKA_BOOTSTRAP.split(","),
        value_serializer=lambda v: json.dumps(v).encode("utf-8"),
        key_serializer=lambda k: k.encode("utf-8"),
        acks="all",
        retries=3,
        linger_ms=0,
        request_timeout_ms=5000,
    )
    futures = [
        (t["symbol"], producer.send(KAFKA_TOPIC, key=t["symbol"], value=t))
        for t in ticks
    ]
    producer.flush()

    success = 0
    for symbol, future in futures:
        try:
            meta = future.get(timeout=5)
            print(f"[KAFKA] {symbol} -> partition={meta.partition} offset={meta.offset}")
            success += 1
        except KafkaError as e:
            print(f"[KAFKA ERR] {symbol}: {e}")

    producer.close()
    return success


# ─────────────────────────────────────────────────────────────────────────────
# Lambda Handler
# ─────────────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Self-invoking tick producer.
    event = {"run_id": "abc123", "tick_count": N}
    """
    run_id     = event["run_id"]
    tick_count = int(event.get("tick_count", 0))

    print(f"[PROD] run={run_id} tick={tick_count}/{TOTAL_TICKS}")

    # ── Guard: check run is still active ─────────────────────────────────────
    run = get_run_state(run_id)
    if not run:
        print(f"[PROD] Run {run_id} not found — aborting")
        return {"aborted": True, "reason": "run_not_found"}

    if run["run_state"] not in ("RUNNING", "STARTING"):
        print(f"[PROD] Run state={run['run_state']} — stopping loop")
        return {"aborted": True, "reason": run["run_state"]}

    # ── Check termination condition ───────────────────────────────────────────
    if tick_count >= TOTAL_TICKS:
        print(f"[PROD] Run {run_id} complete — invoking teardown")
        lambda_.invoke(
            FunctionName=TEARDOWN_LAMBDA_ARN,
            InvocationType="Event",
            Payload=json.dumps({"run_id": run_id, "tick_count": tick_count}),
        )
        return {"completed": True, "run_id": run_id, "ticks": tick_count}

    # ── Generate and publish ticks ────────────────────────────────────────────
    tick_start  = time.time()
    last_prices = get_last_prices()
    ticks       = []
    next_prices = {}

    for symbol, params in STOCKS.items():
        next_price = gbm_next_price(
            current_price=last_prices[symbol],
            volatility=params["volatility"],
            drift=params["drift"],
        )
        ticks.append(build_tick(symbol, next_price))
        next_prices[symbol] = next_price
        print(f"[GBM] {symbol}: {last_prices[symbol]:.4f} -> {next_price:.4f}")

    success = publish_ticks(ticks)

    # ── Persist state ─────────────────────────────────────────────────────────
    new_tick_count = tick_count + 1
    if success > 0:
        save_prices_and_increment(run_id, next_prices, new_tick_count)

    # ── Sleep remainder of 1s interval, then invoke next tick ────────────────
    elapsed = time.time() - tick_start
    sleep_for = max(0, TICK_INTERVAL_S - elapsed)
    print(f"[PROD] Tick took {elapsed:.3f}s, sleeping {sleep_for:.3f}s")
    time.sleep(sleep_for)

    self_arn = PRODUCER_LAMBDA_ARN or context.invoked_function_arn
    lambda_.invoke(
        FunctionName=self_arn,
        InvocationType="Event",
        Payload=json.dumps({
            "run_id":     run_id,
            "tick_count": new_tick_count,
        }),
    )

    return {
        "run_id":     run_id,
        "tick_count": new_tick_count,
        "published":  success,
        "timestamp":  datetime.now(timezone.utc).isoformat(),
    }
