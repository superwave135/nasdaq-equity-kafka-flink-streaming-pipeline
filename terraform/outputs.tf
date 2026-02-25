###############################################################################
# Outputs — stock-streaming-pipeline (event-driven)
###############################################################################

output "vpc_id" {
  value = module.networking.vpc_id
}

output "ecs_cluster_name" {
  value = module.ecs.cluster_name
}

output "dynamodb_table_name" {
  description = "DynamoDB table for run state + price state"
  value       = module.dynamodb.table_name
}

output "lambda_producer_arn"    { value = module.lambda_producer.function_arn }
output "lambda_controller_arn"  { value = module.lambda_controller.function_arn }
output "lambda_teardown_arn"    { value = module.lambda_teardown.function_arn }
output "lambda_status_arn"      { value = module.lambda_status.function_arn }

output "api_base_url" {
  description = "Base URL for the pipeline REST API — paste into dashboard/index.html"
  value       = module.api_gateway.api_url
}

output "api_start_url"  { value = module.api_gateway.api_start_url }
output "api_status_url" { value = module.api_gateway.api_status_url }
output "api_stop_url"   { value = module.api_gateway.api_stop_url }

output "curl_start_command" {
  description = "One-liner to start the pipeline from CLI"
  value       = "curl -X POST ${module.api_gateway.api_start_url}"
}

output "dashboard_url" {
  description = "S3 static website URL for the pipeline dashboard"
  value       = module.dashboard.website_url
}

output "s3_raw_bucket"       { value = module.s3.raw_bucket_name }
output "s3_processed_bucket" { value = module.s3.processed_bucket_name }
output "s3_curated_bucket"   { value = module.s3.curated_bucket_name }
output "s3_scripts_bucket"   { value = module.s3.scripts_bucket_name }
output "glue_database_name"  { value = module.glue.database_name }
output "ecr_repository_urls" { value = module.ecr.repository_urls }
output "sns_alert_topic_arn" { value = module.sns.topic_arn }
output "github_actions_role_arn" { value = module.github_oidc.role_arn }
