###############################################################################
# S3 — Raw, Processed, Curated, Scripts Buckets
###############################################################################

locals {
  buckets = {
    raw       = "${var.name_prefix}-raw-${var.account_id}"
    processed = "${var.name_prefix}-processed-${var.account_id}"
    curated   = "${var.name_prefix}-curated-${var.account_id}"
    scripts   = "${var.name_prefix}-scripts-${var.account_id}"
  }
}

resource "aws_s3_bucket" "buckets" {
  for_each = local.buckets
  bucket   = each.value

  tags = { Name = each.value }
}

resource "aws_s3_bucket_versioning" "buckets" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id

  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "buckets" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "buckets" {
  for_each = local.buckets
  bucket   = aws_s3_bucket.buckets[each.key].id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── Lifecycle: expire raw data after 30 days ─────────────────────────────
resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.buckets["raw"].id

  rule {
    id     = "expire-raw-data"
    status = "Enabled"

    filter {}

    expiration {
      days = 30
    }
  }
}
