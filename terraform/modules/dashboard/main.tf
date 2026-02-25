###############################################################################
# Dashboard — S3 Static Website Hosting
###############################################################################

resource "aws_s3_bucket" "dashboard" {
  bucket = "${var.name_prefix}-dashboard"

  tags = { Name = "${var.name_prefix}-dashboard" }
}

resource "aws_s3_bucket_website_configuration" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  index_document {
    suffix = "index.html"
  }

  error_document {
    key = "index.html"
  }
}

resource "aws_s3_bucket_public_access_block" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_policy" "dashboard" {
  bucket = aws_s3_bucket.dashboard.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "PublicRead"
      Effect    = "Allow"
      Principal = "*"
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.dashboard.arn}/*"
    }]
  })

  depends_on = [aws_s3_bucket_public_access_block.dashboard]
}

# ── Upload index.html with API base URL injected ────────────────────────
resource "aws_s3_object" "index_html" {
  bucket       = aws_s3_bucket.dashboard.id
  key          = "index.html"
  content_type = "text/html"

  # Read the template and inject the API URL
  content = replace(
    file("${path.module}/../../../dashboard/index.html"),
    "API_BASE_URL_PLACEHOLDER",
    var.api_base_url,
  )

  etag = md5(replace(
    file("${path.module}/../../../dashboard/index.html"),
    "API_BASE_URL_PLACEHOLDER",
    var.api_base_url,
  ))
}
