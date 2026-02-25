###############################################################################
# Outputs — DynamoDB Module
###############################################################################

output "table_name" {
  description = "DynamoDB table name"
  value       = aws_dynamodb_table.pipeline_state.name
}

output "table_arn" {
  description = "DynamoDB table ARN"
  value       = aws_dynamodb_table.pipeline_state.arn
}
