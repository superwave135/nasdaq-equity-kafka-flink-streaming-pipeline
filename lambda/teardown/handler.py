"""
Pipeline Teardown Lambda
=========================
Invoked asynchronously by the Producer Lambda after 60 ticks complete,
or by the dashboard Stop button via API Gateway DELETE /pipeline/stop.

Responsibilities:
  1. Update DynamoDB run_state to COMPLETED (or STOPPED)
  2. Stop all ECS services (desired_count = 0)
  3. Trigger Glue ETL job with today's processing date
  4. Return final run summary
"""

import json
import os
import time
from datetime import datetime, timezone

import boto3

# ── Environment ───────────────────────────────────────────────────────────────
AWS_REGION     = os.environ.get("AWS_DEFAULT_REGION", "ap-southeast-1")
DYNAMODB_TABLE = os.environ["DYNAMODB_TABLE"]
ECS_CLUSTER    = os.environ["ECS_CLUSTER"]
ECS_SERVICES   = json.loads(os.environ["ECS_SERVICES"])
GLUE_JOB_NAME       = os.environ["GLUE_JOB_NAME"]
FLUSH_GRACE_PERIOD  = int(os.environ.get("FLUSH_GRACE_PERIOD", "60"))  # seconds to wait for Kafka Connect S3 flush

# ── Clients ───────────────────────────────────────────────────────────────────
dynamodb = boto3.resource("dynamodb", region_name=AWS_REGION)
table    = dynamodb.Table(DYNAMODB_TABLE)
ecs      = boto3.client("ecs",  region_name=AWS_REGION)
glue     = boto3.client("glue", region_name=AWS_REGION)


# ─────────────────────────────────────────────────────────────────────────────
# ECS Teardown
# ─────────────────────────────────────────────────────────────────────────────

def stop_ecs_services():
    """Set desired_count=0 for all pipeline ECS services."""
    stopped = []
    for service in ECS_SERVICES:
        try:
            ecs.update_service(
                cluster=ECS_CLUSTER,
                service=service,
                desiredCount=0,
            )
            print(f"[ECS] Stopped service: {service}")
            stopped.append(service)
        except Exception as e:
            print(f"[ECS WARN] Could not stop {service}: {e}")
    return stopped


# ─────────────────────────────────────────────────────────────────────────────
# Glue ETL Trigger
# ─────────────────────────────────────────────────────────────────────────────

def trigger_glue(run_id: str, processing_date: str) -> str:
    """Start Glue ETL job and return the job run ID."""
    try:
        response = glue.start_job_run(
            JobName=GLUE_JOB_NAME,
            Arguments={
                "--PROCESSING_DATE": processing_date,
                "--run_id":          run_id,
            },
        )
        job_run_id = response["JobRunId"]
        print(f"[GLUE] Started job run: {job_run_id}")
        return job_run_id
    except Exception as e:
        print(f"[GLUE WARN] Could not trigger Glue job: {e}")
        return "FAILED_TO_START"


# ─────────────────────────────────────────────────────────────────────────────
# DynamoDB State
# ─────────────────────────────────────────────────────────────────────────────

def finalise_run(run_id: str, final_state: str, glue_run_id: str, stopped_services: list):
    """Write final state to run record."""
    now = datetime.now(timezone.utc).isoformat()
    table.update_item(
        Key={"pk": "CURRENT_RUN", "sk": "STATE"},
        UpdateExpression=(
            "SET run_state = :rs, completed_at = :ca, updated_at = :ua, "
            "glue_run_id = :gr, ecs_stopped_services = :es"
        ),
        ExpressionAttributeValues={
            ":rs": final_state,
            ":ca": now,
            ":ua": now,
            ":gr": glue_run_id,
            ":es": stopped_services,
        },
    )


# ─────────────────────────────────────────────────────────────────────────────
# Lambda Handler
# ─────────────────────────────────────────────────────────────────────────────

def lambda_handler(event, context):
    """
    Teardown handler.

    Triggered by:
      - Producer Lambda (async) after 60 ticks: event = {"run_id": "...", "tick_count": 60}
      - API Gateway DELETE /pipeline/stop (manual stop): event from API GW
    """
    # Determine if this is an API Gateway call or a direct Lambda invocation
    is_api_call = "httpMethod" in event or "requestContext" in event

    # Extract run_id from either source
    if is_api_call:
        body   = json.loads(event.get("body") or "{}")
        run_id = body.get("run_id")
        final_state = "STOPPED"
    else:
        run_id      = event.get("run_id")
        final_state = "COMPLETED"

    if not run_id:
        # Fall back to current active run
        response = table.get_item(Key={"pk": "CURRENT_RUN", "sk": "STATE"})
        item     = response.get("Item", {})
        run_id   = item.get("run_id", "unknown")

    print(f"[TEAR] Tearing down run={run_id} final_state={final_state}")

    processing_date = datetime.now(timezone.utc).strftime("%Y-%m-%d")

    # ── 1. Flush grace period (let Kafka Connect flush to S3) ────────────────
    if final_state == "COMPLETED" and FLUSH_GRACE_PERIOD > 0:
        print(f"[TEAR] Waiting {FLUSH_GRACE_PERIOD}s for Kafka Connect to flush data to S3...")
        time.sleep(FLUSH_GRACE_PERIOD)
        print("[TEAR] Flush grace period complete")

    # ── 2. Stop ECS services ─────────────────────────────────────────────────
    stopped = stop_ecs_services()

    # ── 3. Trigger Glue ETL (only on natural completion, not manual stop) ────
    glue_run_id = "SKIPPED"
    if final_state == "COMPLETED":
        glue_run_id = trigger_glue(run_id, processing_date)

    # ── 4. Finalise run record ───────────────────────────────────────────────
    finalise_run(run_id, final_state, glue_run_id, stopped)

    result = {
        "run_id":          run_id,
        "final_state":     final_state,
        "stopped_services": stopped,
        "glue_run_id":     glue_run_id,
        "processing_date": processing_date,
        "completed_at":    datetime.now(timezone.utc).isoformat(),
    }

    print(f"[TEAR] Done: {result}")

    if is_api_call:
        return {
            "statusCode": 200,
            "body": json.dumps(result),
            "headers": {
                "Content-Type":                "application/json",
                "Access-Control-Allow-Origin": "*",
            },
        }

    return result
