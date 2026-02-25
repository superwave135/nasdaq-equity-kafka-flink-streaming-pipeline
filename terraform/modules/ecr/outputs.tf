###############################################################################
# Outputs — ECR Module
# Hardcoded keys with try() so main.tf can reference all 4 repos
# even while they are being imported one at a time.
###############################################################################

output "repository_urls" {
  description = "Map of repository short name to ECR URL"
  value = {
    kafka             = try(aws_ecr_repository.repos["kafka"].repository_url, "")
    kafka-connect     = try(aws_ecr_repository.repos["kafka-connect"].repository_url, "")
    flink-jobmanager  = try(aws_ecr_repository.repos["flink-jobmanager"].repository_url, "")
    flink-taskmanager = try(aws_ecr_repository.repos["flink-taskmanager"].repository_url, "")
  }
}
