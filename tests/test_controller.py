"""
Unit tests for the Controller Lambda handler.
Tests idempotency guard, ECS startup flow, and producer invocation.
"""

import json
import os
from unittest.mock import MagicMock, patch, call

import pytest

os.environ.setdefault("DYNAMODB_TABLE", "test-pipeline-state")
os.environ.setdefault("ECS_CLUSTER", "test-cluster")
os.environ.setdefault("ECS_SERVICES", '["svc-kafka","svc-connect","svc-flink-jm","svc-flink-tm"]')
os.environ.setdefault("PRODUCER_LAMBDA_ARN", "arn:aws:lambda:ap-southeast-1:123456789:function:test-producer")
os.environ.setdefault("TOTAL_TICKS", "60")
os.environ.setdefault("ECS_READY_TIMEOUT", "5")


# ── Idempotency Guard ───────────────────────────────────────────────────────

class TestIdempotencyGuard:
    @patch("lambda_.controller.handler.lambda_")
    @patch("lambda_.controller.handler.wait_for_services_stable", return_value=True)
    @patch("lambda_.controller.handler.start_ecs_services")
    @patch("lambda_.controller.handler.create_run")
    @patch("lambda_.controller.handler.update_run_state")
    @patch("lambda_.controller.handler.get_active_run")
    def test_returns_409_if_pipeline_already_running(
        self, mock_active, mock_update, mock_create, mock_start, mock_wait, mock_lambda
    ):
        from lambda_.controller.handler import lambda_handler

        mock_active.return_value = {
            "run_id": "existing", "run_state": "RUNNING", "tick_count": 30
        }

        result = lambda_handler({}, None)

        assert result["statusCode"] == 409
        body = json.loads(result["body"])
        assert body["run_id"] == "existing"
        mock_create.assert_not_called()

    @patch("lambda_.controller.handler.lambda_")
    @patch("lambda_.controller.handler.wait_for_services_stable", return_value=True)
    @patch("lambda_.controller.handler.start_ecs_services")
    @patch("lambda_.controller.handler.create_run")
    @patch("lambda_.controller.handler.update_run_state")
    @patch("lambda_.controller.handler.get_active_run")
    def test_starts_pipeline_when_no_active_run(
        self, mock_active, mock_update, mock_create, mock_start, mock_wait, mock_lambda
    ):
        from lambda_.controller.handler import lambda_handler

        mock_active.return_value = None

        result = lambda_handler({}, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["message"] == "Pipeline started"
        assert "run_id" in body
        mock_create.assert_called_once()
        mock_start.assert_called_once()


# ── ECS Startup Flow ────────────────────────────────────────────────────────

class TestECSStartup:
    @patch("lambda_.controller.handler.lambda_")
    @patch("lambda_.controller.handler.wait_for_services_stable", return_value=False)
    @patch("lambda_.controller.handler.start_ecs_services")
    @patch("lambda_.controller.handler.create_run")
    @patch("lambda_.controller.handler.update_run_state")
    @patch("lambda_.controller.handler.get_active_run", return_value=None)
    def test_returns_503_when_ecs_fails_to_stabilise(
        self, mock_active, mock_update, mock_create, mock_start, mock_wait, mock_lambda
    ):
        from lambda_.controller.handler import lambda_handler

        result = lambda_handler({}, None)

        assert result["statusCode"] == 503
        body = json.loads(result["body"])
        assert "timeout" in body["error"].lower() or "failed" in body["error"].lower()
        mock_lambda.invoke.assert_not_called()


# ── Producer Invocation ──────────────────────────────────────────────────────

class TestProducerInvocation:
    @patch("lambda_.controller.handler.lambda_")
    @patch("lambda_.controller.handler.wait_for_services_stable", return_value=True)
    @patch("lambda_.controller.handler.start_ecs_services")
    @patch("lambda_.controller.handler.create_run")
    @patch("lambda_.controller.handler.update_run_state")
    @patch("lambda_.controller.handler.get_active_run", return_value=None)
    def test_invokes_producer_async_with_tick_0(
        self, mock_active, mock_update, mock_create, mock_start, mock_wait, mock_lambda
    ):
        from lambda_.controller.handler import lambda_handler

        result = lambda_handler({}, None)

        mock_lambda.invoke.assert_called_once()
        call_kwargs = mock_lambda.invoke.call_args[1]
        assert call_kwargs["InvocationType"] == "Event"
        payload = json.loads(call_kwargs["Payload"])
        assert payload["tick_count"] == 0
        assert "run_id" in payload


# ── CORS Headers ─────────────────────────────────────────────────────────────

class TestCORSHeaders:
    @patch("lambda_.controller.handler.lambda_")
    @patch("lambda_.controller.handler.wait_for_services_stable", return_value=True)
    @patch("lambda_.controller.handler.start_ecs_services")
    @patch("lambda_.controller.handler.create_run")
    @patch("lambda_.controller.handler.update_run_state")
    @patch("lambda_.controller.handler.get_active_run", return_value=None)
    def test_response_includes_cors_headers(
        self, mock_active, mock_update, mock_create, mock_start, mock_wait, mock_lambda
    ):
        from lambda_.controller.handler import lambda_handler

        result = lambda_handler({}, None)

        assert "Access-Control-Allow-Origin" in result["headers"]
        assert result["headers"]["Access-Control-Allow-Origin"] == "*"
