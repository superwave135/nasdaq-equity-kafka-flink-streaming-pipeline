###############################################################################
# DynamoDB — Pipeline State (single-table design)
#
# Key patterns:
#   pk=CURRENT_RUN, sk=STATE  → run metadata, tick_count, run_state, prices
#   pk=PRICE_STATE, sk=SYMBOL → last GBM price per symbol (cross-invocation)
###############################################################################

resource "aws_dynamodb_table" "pipeline_state" {
  name         = "${var.name_prefix}-pipeline-state"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "pk"
  range_key    = "sk"

  attribute {
    name = "pk"
    type = "S"
  }

  attribute {
    name = "sk"
    type = "S"
  }

  ttl {
    attribute_name = "ttl"
    enabled        = true
  }

  point_in_time_recovery {
    enabled = var.environment == "prod"
  }

  tags = { Name = "${var.name_prefix}-pipeline-state" }
}
