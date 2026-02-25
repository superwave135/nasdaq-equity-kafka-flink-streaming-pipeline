###############################################################################
# Outputs — S3 Module
# try() guards allow terraform import to proceed one bucket at a time
# without failing on map keys not yet in state.
###############################################################################

output "raw_bucket_arn" {
  value = try(aws_s3_bucket.buckets["raw"].arn, "")
}

output "raw_bucket_name" {
  value = try(aws_s3_bucket.buckets["raw"].id, "")
}

output "processed_bucket_arn" {
  value = try(aws_s3_bucket.buckets["processed"].arn, "")
}

output "processed_bucket_name" {
  value = try(aws_s3_bucket.buckets["processed"].id, "")
}

output "curated_bucket_arn" {
  value = try(aws_s3_bucket.buckets["curated"].arn, "")
}

output "curated_bucket_name" {
  value = try(aws_s3_bucket.buckets["curated"].id, "")
}

output "scripts_bucket_arn" {
  value = try(aws_s3_bucket.buckets["scripts"].arn, "")
}

output "scripts_bucket_name" {
  value = try(aws_s3_bucket.buckets["scripts"].id, "")
}
