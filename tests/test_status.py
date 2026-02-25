"""
Unit tests for the Status Lambda handler.
Tests IDLE response, active run response, price fetching, and CORS headers.
"""

import json
import os
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest

os.environ.setdefault("DYNAMODB_TABLE", "test-pipeline-state")


# ── IDLE State (No Active Run) ────────────────────────────────────────────────

class TestIdleState:
    @patch("lambda_.status.handler.table")
    def test_returns_idle_when_no_run_record(self, mock_table):
        from lambda_.status.handler import lambda_handler

        mock_table.get_item.return_value = {}

        result = lambda_handler({}, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["run_state"] == "IDLE"
        assert body["tick_count"] == 0
        assert body["total_ticks"] == 60
        assert body["last_prices"] == {}
        assert body["run_id"] is None


# ── Active Run Response ───────────────────────────────────────────────────────

class TestActiveRun:
    @patch("lambda_.status.handler.table")
    def test_returns_running_state_with_tick_count(self, mock_table):
        from lambda_.status.handler import lambda_handler

        mock_table.get_item.return_value = {
            "Item": {
                "pk": "CURRENT_RUN",
                "sk": "STATE",
                "run_id": "run-123",
                "run_state": "RUNNING",
                "tick_count": Decimal("34"),
                "total_ticks": Decimal("60"),
                "started_at": "2025-01-01T00:00:00+00:00",
            }
        }
        mock_table.query.return_value = {
            "Items": [
                {"pk": "PRICE_STATE", "sk": "AAPL", "last_price": Decimal("185.50")},
                {"pk": "PRICE_STATE", "sk": "MSFT", "last_price": Decimal("420.00")},
            ]
        }

        result = lambda_handler({}, None)

        assert result["statusCode"] == 200
        body = json.loads(result["body"])
        assert body["run_state"] == "RUNNING"
        assert body["run_id"] == "run-123"
        assert body["tick_count"] == 34
        assert body["total_ticks"] == 60
        assert body["last_prices"]["AAPL"] == 185.50
        assert body["last_prices"]["MSFT"] == 420.00

    @patch("lambda_.status.handler.table")
    def test_returns_completed_state(self, mock_table):
        from lambda_.status.handler import lambda_handler

        mock_table.get_item.return_value = {
            "Item": {
                "pk": "CURRENT_RUN",
                "sk": "STATE",
                "run_id": "run-456",
                "run_state": "COMPLETED",
                "tick_count": Decimal("60"),
                "total_ticks": Decimal("60"),
                "started_at": "2025-01-01T00:00:00+00:00",
                "completed_at": "2025-01-01T00:01:00+00:00",
                "glue_run_id": "jr_abc123",
            }
        }
        mock_table.query.return_value = {"Items": []}

        result = lambda_handler({}, None)

        body = json.loads(result["body"])
        assert body["run_state"] == "COMPLETED"
        assert body["tick_count"] == 60
        assert body["progress_pct"] == 100.0
        assert body["glue_run_id"] == "jr_abc123"


# ── Progress Calculation ──────────────────────────────────────────────────────

class TestProgress:
    @patch("lambda_.status.handler.table")
    def test_calculates_progress_percentage(self, mock_table):
        from lambda_.status.handler import lambda_handler

        mock_table.get_item.return_value = {
            "Item": {
                "pk": "CURRENT_RUN",
                "sk": "STATE",
                "run_id": "run-789",
                "run_state": "RUNNING",
                "tick_count": Decimal("30"),
                "total_ticks": Decimal("60"),
                "started_at": "2025-01-01T00:00:00+00:00",
            }
        }
        mock_table.query.return_value = {"Items": []}

        result = lambda_handler({}, None)

        body = json.loads(result["body"])
        assert body["progress_pct"] == 50.0


# ── CORS Headers ──────────────────────────────────────────────────────────────

class TestCORSHeaders:
    @patch("lambda_.status.handler.table")
    def test_response_includes_cors_headers(self, mock_table):
        from lambda_.status.handler import lambda_handler

        mock_table.get_item.return_value = {}

        result = lambda_handler({}, None)

        assert "Access-Control-Allow-Origin" in result["headers"]
        assert result["headers"]["Access-Control-Allow-Origin"] == "*"
