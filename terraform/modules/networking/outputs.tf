###############################################################################
# Outputs — Networking Module
###############################################################################

output "vpc_id" {
  description = "ID of the VPC"
  value       = aws_vpc.main.id
}

output "private_subnet_ids" {
  description = "List of private subnet IDs (ECS services + Lambda)"
  value       = aws_subnet.private[*].id
}

output "public_subnet_ids" {
  description = "List of public subnet IDs (NAT gateway)"
  value       = aws_subnet.public[*].id
}

output "ecs_sg_id" {
  description = "Security group ID for ECS services (Kafka, Connect, Flink)"
  value       = aws_security_group.ecs.id
}

output "lambda_sg_id" {
  description = "Security group ID for Lambda functions"
  value       = aws_security_group.lambda.id
}

output "service_discovery_namespace_id" {
  description = "Cloud Map private DNS namespace ID"
  value       = aws_service_discovery_private_dns_namespace.main.id
}

output "service_discovery_namespace_name" {
  description = "Cloud Map private DNS namespace name (e.g. stock-streaming-dev.local)"
  value       = aws_service_discovery_private_dns_namespace.main.name
}
