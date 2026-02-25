"""
Unit tests for the Teardown Lambda handler.
Tests ECS shutdown, Glue trigger logic, and API vs direct invocation paths.
"""

import json
import os
from unittest.mock import MagicMock, patch

import pytest

os.environ.setdefault("DYNAMODB_TABLE", "test-pipeline-state")
os.environ.setdefault("ECS_CLUSTER", "test-cluster")
os.environ.setdefault("ECS_SERVICES", '["svc-kafka","svc-connect","svc-flink-jm","svc-flink-tm"]')
os.environ.setdefault("GLUE_JOB_NAME", "test-curated-layer-builder")
os.environ.setdefault("FLUSH_GRACE_PERIOD", "0")  # skip S3 flush wait in tests


# ── ECS Shutdown ─────────────────────────────────────────────────────────────

class TestECSShutdown:
    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue", return_value="jr-123")
    @patch("lambda_.teardown.handler.stop_ecs_services")
    def test_stops_all_ecs_services(self, mock_stop, mock_glue, mock_finalise):
        from lambda_.teardown.handler import lambda_handler

        mock_stop.return_value = ["svc-kafka", "svc-connect", "svc-flink-jm", "svc-flink-tm"]

        result = lambda_handler({"run_id": "abc", "tick_count": 60}, None)

        mock_stop.assert_called_once()
        assert len(result["stopped_services"]) == 4


# ── Glue Trigger Logic ──────────────────────────────────────────────────────

class TestGlueTrigger:
    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue", return_value="jr-456")
    @patch("lambda_.teardown.handler.stop_ecs_services", return_value=[])
    def test_triggers_glue_on_natural_completion(self, mock_stop, mock_glue, mock_finalise):
        from lambda_.teardown.handler import lambda_handler

        # Direct invocation from producer (not API Gateway) = COMPLETED
        result = lambda_handler({"run_id": "abc", "tick_count": 60}, None)

        mock_glue.assert_called_once()
        assert result["final_state"] == "COMPLETED"
        assert result["glue_run_id"] == "jr-456"

    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue")
    @patch("lambda_.teardown.handler.stop_ecs_services", return_value=[])
    def test_skips_glue_on_manual_stop(self, mock_stop, mock_glue, mock_finalise):
        from lambda_.teardown.handler import lambda_handler

        # API Gateway invocation (manual stop) = STOPPED
        api_event = {
            "httpMethod": "DELETE",
            "requestContext": {},
            "body": json.dumps({"run_id": "abc"}),
        }
        result = lambda_handler(api_event, None)

        mock_glue.assert_not_called()
        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["final_state"] == "STOPPED"
        assert body["glue_run_id"] == "SKIPPED"


# ── Invocation Paths ─────────────────────────────────────────────────────────

class TestInvocationPaths:
    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue", return_value="jr-789")
    @patch("lambda_.teardown.handler.stop_ecs_services", return_value=[])
    def test_direct_invocation_returns_plain_dict(self, mock_stop, mock_glue, mock_finalise):
        from lambda_.teardown.handler import lambda_handler

        result = lambda_handler({"run_id": "abc", "tick_count": 60}, None)

        # Direct invocation returns a plain dict (no statusCode wrapper)
        assert "statusCode" not in result
        assert result["run_id"] == "abc"
        assert result["final_state"] == "COMPLETED"

    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue")
    @patch("lambda_.teardown.handler.stop_ecs_services", return_value=[])
    def test_api_invocation_returns_api_gateway_response(self, mock_stop, mock_glue, mock_finalise):
        from lambda_.teardown.handler import lambda_handler

        api_event = {
            "httpMethod": "DELETE",
            "requestContext": {},
            "body": json.dumps({"run_id": "xyz"}),
        }
        result = lambda_handler(api_event, None)

        assert result["statusCode"] == 200
        assert "Access-Control-Allow-Origin" in result["headers"]

    @patch("lambda_.teardown.handler.finalise_run")
    @patch("lambda_.teardown.handler.trigger_glue", return_value="jr-000")
    @patch("lambda_.teardown.handler.stop_ecs_services", return_value=[])
    @patch("lambda_.teardown.handler.table")
    def test_falls_back_to_current_run_if_no_run_id(
        self, mock_table, mock_stop, mock_glue, mock_finalise
    ):
        from lambda_.teardown.handler import lambda_handler

        mock_table.get_item.return_value = {
            "Item": {"run_id": "fallback-id", "run_state": "RUNNING"}
        }

        result = lambda_handler({}, None)

        assert result["run_id"] == "fallback-id"
