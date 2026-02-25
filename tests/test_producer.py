"""
Unit tests for the Producer Lambda handler.
Tests GBM price simulation, tick building, and handler control flow.
"""

import json
import math
import os
import sys
from datetime import datetime, timezone
from decimal import Decimal
from unittest.mock import MagicMock, patch

import pytest

# Set required environment variables before importing handler
os.environ.setdefault("KAFKA_BOOTSTRAP_SERVERS", "localhost:9092")
os.environ.setdefault("DYNAMODB_TABLE", "test-pipeline-state")
os.environ.setdefault("PRODUCER_LAMBDA_ARN", "arn:aws:lambda:ap-southeast-1:123456789:function:test-producer")
os.environ.setdefault("TEARDOWN_LAMBDA_ARN", "arn:aws:lambda:ap-southeast-1:123456789:function:test-teardown")
os.environ.setdefault("TOTAL_TICKS", "60")


# ── GBM Price Simulation ────────────────────────────────────────────────────

class TestGBMNextPrice:
    """Test the Geometric Brownian Motion price generator."""

    @patch("random.gauss", return_value=0.0)
    def test_zero_noise_returns_drift_only(self, mock_gauss):
        from lambda_.producer.handler import gbm_next_price

        price = gbm_next_price(100.0, volatility=0.25, drift=0.08)
        # With Z=0, price should barely change (drift only, sub-second dt)
        assert 99.99 < price < 100.01

    @patch("random.gauss", return_value=1.0)
    def test_positive_noise_increases_price(self, mock_gauss):
        from lambda_.producer.handler import gbm_next_price

        price = gbm_next_price(100.0, volatility=0.25, drift=0.08)
        assert price > 100.0

    @patch("random.gauss", return_value=-1.0)
    def test_negative_noise_decreases_price(self, mock_gauss):
        from lambda_.producer.handler import gbm_next_price

        price = gbm_next_price(100.0, volatility=0.25, drift=0.08)
        assert price < 100.0

    def test_price_is_always_positive(self):
        from lambda_.producer.handler import gbm_next_price

        # Run many iterations — GBM should never produce negative prices
        price = 100.0
        for _ in range(1000):
            price = gbm_next_price(price, volatility=0.45, drift=0.0)
        assert price > 0

    def test_higher_volatility_produces_wider_range(self):
        from lambda_.producer.handler import gbm_next_price

        low_vol_prices = []
        high_vol_prices = []
        for _ in range(500):
            low_vol_prices.append(gbm_next_price(100.0, volatility=0.05, drift=0.0))
            high_vol_prices.append(gbm_next_price(100.0, volatility=0.50, drift=0.0))

        low_range = max(low_vol_prices) - min(low_vol_prices)
        high_range = max(high_vol_prices) - min(high_vol_prices)
        assert high_range > low_range


# ── Tick Building ────────────────────────────────────────────────────────────

class TestBuildTick:
    def test_tick_has_required_fields(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("AAPL", 182.50)
        required = {"symbol", "timestamp", "price", "volume", "bid", "ask", "spread", "source"}
        assert required.issubset(tick.keys())

    def test_tick_symbol_matches(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("NVDA", 875.00)
        assert tick["symbol"] == "NVDA"

    def test_tick_price_is_rounded(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("AAPL", 182.123456789)
        # price should be rounded to 4 decimal places
        assert tick["price"] == round(182.123456789, 4)

    def test_bid_less_than_ask(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("MSFT", 415.00)
        assert tick["bid"] < tick["ask"]

    def test_spread_is_positive(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("GOOGL", 175.00)
        assert tick["spread"] > 0

    def test_volume_is_positive_integer(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("AMZN", 195.00)
        assert isinstance(tick["volume"], int)
        assert tick["volume"] > 0

    def test_source_is_simulator(self):
        from lambda_.producer.handler import build_tick

        tick = build_tick("AAPL", 182.00)
        assert tick["source"] == "simulator"


# ── Handler Control Flow ────────────────────────────────────────────────────

class TestProducerHandler:
    @patch("lambda_.producer.handler.lambda_")
    @patch("lambda_.producer.handler.publish_ticks", return_value=5)
    @patch("lambda_.producer.handler.save_prices_and_increment")
    @patch("lambda_.producer.handler.get_last_prices")
    @patch("lambda_.producer.handler.get_run_state")
    @patch("time.sleep")
    def test_normal_tick_invokes_self(
        self, mock_sleep, mock_run_state, mock_prices, mock_save, mock_publish, mock_lambda
    ):
        from lambda_.producer.handler import lambda_handler

        mock_run_state.return_value = {"run_id": "abc", "run_state": "RUNNING"}
        mock_prices.return_value = {
            "AAPL": 182.0, "MSFT": 415.0, "GOOGL": 175.0, "AMZN": 195.0, "NVDA": 875.0
        }

        result = lambda_handler({"run_id": "abc", "tick_count": 5}, None)

        assert result["tick_count"] == 6
        assert result["published"] == 5
        mock_lambda.invoke.assert_called_once()
        call_args = mock_lambda.invoke.call_args
        assert call_args[1]["InvocationType"] == "Event"

    @patch("lambda_.producer.handler.lambda_")
    @patch("lambda_.producer.handler.get_run_state")
    def test_final_tick_invokes_teardown(self, mock_run_state, mock_lambda):
        from lambda_.producer.handler import lambda_handler, TOTAL_TICKS

        mock_run_state.return_value = {"run_id": "abc", "run_state": "RUNNING"}

        result = lambda_handler({"run_id": "abc", "tick_count": TOTAL_TICKS}, None)

        assert result["completed"] is True
        mock_lambda.invoke.assert_called_once()
        call_args = mock_lambda.invoke.call_args
        payload = json.loads(call_args[1]["Payload"])
        assert payload["tick_count"] == TOTAL_TICKS

    @patch("lambda_.producer.handler.get_run_state")
    def test_aborts_if_run_not_found(self, mock_run_state):
        from lambda_.producer.handler import lambda_handler

        mock_run_state.return_value = None

        result = lambda_handler({"run_id": "missing", "tick_count": 0}, None)

        assert result["aborted"] is True
        assert result["reason"] == "run_not_found"

    @patch("lambda_.producer.handler.get_run_state")
    def test_aborts_if_run_stopped(self, mock_run_state):
        from lambda_.producer.handler import lambda_handler

        mock_run_state.return_value = {"run_id": "abc", "run_state": "STOPPED"}

        result = lambda_handler({"run_id": "abc", "tick_count": 10}, None)

        assert result["aborted"] is True
        assert result["reason"] == "STOPPED"
