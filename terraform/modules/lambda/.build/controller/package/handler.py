"""
Pipeline Controller Lambda
===========================
Triggered by API Gateway POST /pipeline/start

Responsibilities:
  1. Guard against concurrent runs (idempotency check)
  2. Write RUN record to DynamoDB (state = STARTING)
  3. Start all ECS services (desired_count = 1)
  4. Poll until all services are stable / healthy
  5. Invoke Producer Lambda asynchronously to begin the tick loop
  6. Return run_id to caller immediately (non-blocking)

The producer self-invokes every ~1 second for 60 ticks, then
invokes the Teardown Lambda to stop ECS and trigger Glue ETL.
"""

import json
import os
import time
import uuid
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

# ── Environment ───────────────────────────────────────────────────────────────
AWS_REGION          = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")
DYNAMODB_TABLE      = os.environ["DYNAMODB_TABLE"]           # run-state table
ECS_CLUSTER         = os.environ["ECS_CLUSTER"]
ECS_SERVICES        = json.loads(os.environ["ECS_SERVICES"]) # list of service names
PRODUCER_LAMBDA_ARN = os.environ["PRODUCER_LAMBDA_ARN"]
TOTAL_TICKS         = int(os.environ.get("TOTAL_TICKS", "60"))
ECS_READY_TIMEOUT   = int(os.environ.get("ECS_READY_TIMEOUT", "120"))  # seconds

# ── Clients ───────────────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMODB_TABLE)
ecs      = boto3.client("ecs",    region_name=AWS_REGION)
lambda_  = boto3.client("lambda", region_name=AWS_REGION)


# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB Run State
# ─────────────────────────────────────────────────────────────────────────────

def get_active_run() -> dict | None:
    """Return the current active run record, or None if no run is in progress."""
    response = table.get_item(Key={"pk": "CURRENT_RUN", "sk": "STATE"})
    item = response.get("Item")
    if item and item.get("run_state") in ("STARTING", "RUNNING"):
        return item
    return None


def create_run(run_id: str) -> None:
    """Write a new run record — fails if another run is already active."""
    now = datetime.now(timezone.utc).isoformat()
    table.put_item(
        Item={
            "pk":          "CURRENT_RUN",
            "sk":          "STATE",
            "run_id":      run_id,
            "run_state":   "STARTING",
            "tick_count":  0,
            "total_ticks": TOTAL_TICKS,
            "started_at":  now,
            "updated_at":  now,
        },
        ConditionExpression="attribute_not_exists(pk) OR run_state IN (:done, :failed, :stopped)",
        ExpressionAttributeValues={
            ":done":    "COMPLETED",
            ":failed":  "FAILED",
            ":stopped": "STOPPED",
        },
    )


def update_run_state(run_id: str, state: str, extra: dict = None) -> None:
    """Update run_state and updated_at on the current run record."""
    expr_names  = {"#s": "run_state", "#u": "updated_at"}
    expr_values = {
        ":state":   state,
        ":updated": datetime.now(timezone.utc).isoformat(),
    }
    update_expr = "SET #s = :state, #u = :updated"

    if extra:
        for k, v in extra.items():
            safe_key = f"#attr_{k}"
            val_key  = f":val_{k}"
            expr_names[safe_key]  = k
            expr_values[val_key]  = v
            update_expr          += f", {safe_key} = {val_key}"

    table.update_item(
        Key={"pk": "CURRENT_RUN", "sk": "STATE"},
        UpdateExpression=update_expr,
        ExpressionAttributeNames=expr_names,
        ExpressionAttributeValues=expr_values,
    )


# ─────────────────────────────────────────────────────────────────────────────
# ECS Service Management
# ─────────────────────────────────────────────────────────────────────────────

def start_ecs_services() -> None:
    """Set desired_count=1 for all pipeline ECS services."""
    for service in ECS_SERVICES:
        ecs.update_service(
            cluster=ECS_CLUSTER,
            service=service,
            desiredCount=1,
        )
        print(f"[ECS] Started service: {service}")


def wait_for_services_stable(timeout: int = ECS_READY_TIMEOUT) -> bool:
    """
    Poll ECS until all services report runningCount == 1.
    Returns True if stable within timeout, False otherwise.
    """
    deadline = time.time() + timeout
    pending  = set(ECS_SERVICES)

    while time.time() < deadline and pending:
        response = ecs.describe_services(
            cluster=ECS_CLUSTER,
            services=list(pending),
        )
        still_pending = set()
        for svc in response["services"]:
            name    = svc["serviceName"]
            running = svc["runningCount"]
            desired = svc["desiredCount"]
            print(f"[ECS] {name}: running={running}/{desired}")
            if running < 1 or running < desired:
                still_pending.add(name)

        pending = still_pending
        if pending:
            time.sleep(5)

    return len(pending) == 0


# ─────────────────────────────────────────────────────────────────────────────
# Lambda Handler
# ─────────────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    POST /pipeline/start handler.

    Returns immediately with run_id after kicking off the async producer loop.
    The full 60-second pipeline runs asynchronously — poll GET /pipeline/status
    to track progress.
    """
    run_id = str(uuid.uuid4())[:8]  # short ID for display

    # ── 1. Idempotency guard ─────────────────────────────────────────────────
    active = get_active_run()
    if active:
        return {
            "statusCode": 409,
            "body": json.dumps({
                "error":   "Pipeline already running",
                "run_id":  active["run_id"],
                "state":   active["run_state"],
                "ticks":   int(active.get("tick_count", 0)),
            }),
            "headers": cors_headers(),
        }

    # ── 2. Create run record ─────────────────────────────────────────────────
    try:
        create_run(run_id)
        print(f"[CTRL] Run {run_id} created")
    except ClientError as e:
        if e.response["Error"]["Code"] == "ConditionalCheckFailedException":
            return {
                "statusCode": 409,
                "body": json.dumps({"error": "Pipeline already running"}),
                "headers": cors_headers(),
            }
        raise

    # ── 3. Start ECS services ────────────────────────────────────────────────
    try:
        start_ecs_services()
        update_run_state(run_id, "STARTING", {"ecs_start_time": datetime.now(timezone.utc).isoformat()})
    except Exception as e:
        update_run_state(run_id, "FAILED", {"error": str(e)})
        raise

    # ── 4. Wait for ECS to be stable ─────────────────────────────────────────
    print(f"[CTRL] Waiting for ECS services to stabilise (timeout={ECS_READY_TIMEOUT}s)...")
    stable = wait_for_services_stable(timeout=ECS_READY_TIMEOUT)

    if not stable:
        update_run_state(run_id, "FAILED", {"error": "ECS services did not stabilise in time"})
        return {
            "statusCode": 503,
            "body": json.dumps({
                "error":  "ECS services failed to start within timeout",
                "run_id": run_id,
            }),
            "headers": cors_headers(),
        }

    update_run_state(run_id, "RUNNING", {"ecs_ready_time": datetime.now(timezone.utc).isoformat()})
    print(f"[CTRL] All ECS services stable. Invoking producer for run {run_id}")

    # ── 5. Kick off async producer loop ──────────────────────────────────────
    lambda_.invoke(
        FunctionName=PRODUCER_LAMBDA_ARN,
        InvocationType="Event",          # async — returns immediately
        Payload=json.dumps({
            "run_id":    run_id,
            "tick_count": 0,
        }),
    )

    return {
        "statusCode": 200,
        "body": json.dumps({
            "message":     "Pipeline started",
            "run_id":      run_id,
            "total_ticks": TOTAL_TICKS,
            "status_url":  "/pipeline/status",
        }),
        "headers": cors_headers(),
    }


def cors_headers() -> dict:
    return {
        "Content-Type":                "application/json",
        "Access-Control-Allow-Origin": "*",
        "Access-Control-Allow-Methods": "GET,POST,OPTIONS",
        "Access-Control-Allow-Headers": "Content-Type",
    }
