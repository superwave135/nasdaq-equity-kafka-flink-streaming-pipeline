###############################################################################
# Outputs — ECS Kafka Module
###############################################################################

output "service_arn" {
  description = "Kafka ECS service ARN"
  value       = aws_ecs_service.kafka.id
}

output "service_name" {
  description = "Kafka ECS service name"
  value       = aws_ecs_service.kafka.name
}

output "service_discovery_endpoint" {
  description = "Kafka broker DNS endpoint (e.g. kafka.stock-streaming-dev.local)"
  value       = "kafka.${var.service_discovery_namespace_name}"
}
