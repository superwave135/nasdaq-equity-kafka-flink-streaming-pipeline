###############################################################################
# Outputs — ECS Kafka Connect Module
###############################################################################

output "service_arn" {
  value = aws_ecs_service.connect.id
}

output "service_name" {
  value = aws_ecs_service.connect.name
}
