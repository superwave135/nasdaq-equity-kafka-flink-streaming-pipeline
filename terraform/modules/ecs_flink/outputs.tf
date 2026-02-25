###############################################################################
# Outputs — ECS Flink Module
###############################################################################

output "service_arn" {
  value = aws_ecs_service.flink.id
}

output "service_name" {
  value = aws_ecs_service.flink.name
}

output "service_discovery_endpoint" {
  description = "Flink service discovery DNS (e.g. flink-jobmanager.stock-streaming-dev.local)"
  value       = "flink-${var.role}.${var.service_discovery_namespace_name}"
}
