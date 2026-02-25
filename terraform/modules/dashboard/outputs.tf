###############################################################################
# Outputs — Dashboard Module
###############################################################################

output "website_url" {
  description = "S3 static website URL for the pipeline dashboard"
  value       = aws_s3_bucket_website_configuration.dashboard.website_endpoint
}
