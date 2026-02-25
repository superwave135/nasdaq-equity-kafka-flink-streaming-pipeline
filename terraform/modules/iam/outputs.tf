###############################################################################
# Outputs — IAM Module
###############################################################################

output "ecs_execution_role_arn" {
  description = "ECS task execution role ARN (pull images, push logs)"
  value       = aws_iam_role.ecs_execution.arn
}

output "ecs_task_role_arn" {
  description = "ECS task role ARN (container runtime permissions)"
  value       = aws_iam_role.ecs_task.arn
}

output "lambda_role_arn" {
  description = "Lambda execution role ARN (shared across all functions)"
  value       = aws_iam_role.lambda.arn
}

output "glue_role_arn" {
  description = "Glue service role ARN"
  value       = aws_iam_role.glue.arn
}

output "eventbridge_scheduler_role_arn" {
  description = "EventBridge Scheduler role ARN"
  value       = aws_iam_role.eventbridge_scheduler.arn
}
