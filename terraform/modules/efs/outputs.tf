###############################################################################
# Outputs — EFS Module
###############################################################################

output "file_system_id" {
  description = "EFS file system ID"
  value       = aws_efs_file_system.main.id
}

output "access_point_id" {
  description = "EFS access point ID for Kafka"
  value       = aws_efs_access_point.kafka.id
}
