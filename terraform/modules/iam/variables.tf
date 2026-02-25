###############################################################################
# Variables — IAM Module
###############################################################################

variable "name_prefix" {
  description = "Resource name prefix (project-environment)"
  type        = string
}

variable "environment" {
  description = "Deployment environment (dev / staging / prod)"
  type        = string
}

variable "account_id" {
  description = "AWS account ID"
  type        = string
}

variable "region" {
  description = "AWS region"
  type        = string
}

variable "s3_raw_bucket_arn" {
  description = "ARN of the raw S3 bucket"
  type        = string
}

variable "s3_proc_bucket_arn" {
  description = "ARN of the processed S3 bucket"
  type        = string
}

variable "s3_cur_bucket_arn" {
  description = "ARN of the curated S3 bucket"
  type        = string
}

variable "s3_scripts_bucket_arn" {
  description = "ARN of the scripts S3 bucket"
  type        = string
}

variable "dynamodb_table_arn" {
  description = "ARN of the DynamoDB pipeline-state table"
  type        = string
}
