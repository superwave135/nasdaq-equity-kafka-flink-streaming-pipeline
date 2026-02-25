###############################################################################
# stock-streaming-pipeline — Root Terraform Module
# Mirrors the structure of nasdaq-equity-airflow-ecs-pipeline for consistency
###############################################################################

terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    # Populated via terraform init -backend-config=envs/dev/backend.hcl
    key = "stock-streaming-pipeline/terraform.tfstate"
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project     = "stock-streaming-pipeline"
      Environment = var.environment
      ManagedBy   = "terraform"
      Owner       = var.owner
    }
  }
}

# ── Data Sources ──────────────────────────────────────────────────────────────
data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name
  name_prefix = "${var.project_name}-${var.environment}"
}

# ── Networking ────────────────────────────────────────────────────────────────
module "networking" {
  source = "./modules/networking"

  name_prefix        = local.name_prefix
  vpc_cidr           = var.vpc_cidr
  availability_zones = var.availability_zones
  environment        = var.environment
}

# ── S3 Buckets ────────────────────────────────────────────────────────────────
module "s3" {
  source = "./modules/s3"

  name_prefix  = local.name_prefix
  environment  = var.environment
  aws_region   = var.aws_region
  account_id   = local.account_id
}

# ── ECR Repositories ──────────────────────────────────────────────────────────
module "ecr" {
  source = "./modules/ecr"

  name_prefix = local.name_prefix
  environment = var.environment
  repositories = [
    "kafka",
    "kafka-connect",
    "flink-jobmanager",
    "flink-taskmanager",
  ]
}

# ── DynamoDB (Lambda producer state) ─────────────────────────────────────────
module "dynamodb" {
  source = "./modules/dynamodb"

  name_prefix = local.name_prefix
  environment = var.environment
}

# ── IAM Roles ────────────────────────────────────────────────────────────────
module "iam" {
  source = "./modules/iam"

  name_prefix        = local.name_prefix
  environment        = var.environment
  account_id         = local.account_id
  region             = local.region
  s3_raw_bucket_arn      = module.s3.raw_bucket_arn
  s3_proc_bucket_arn     = module.s3.processed_bucket_arn
  s3_cur_bucket_arn      = module.s3.curated_bucket_arn
  s3_scripts_bucket_arn  = module.s3.scripts_bucket_arn
  dynamodb_table_arn     = module.dynamodb.table_arn
}

# ── ECS Cluster ───────────────────────────────────────────────────────────────
module "ecs" {
  source = "./modules/ecs"

  name_prefix = local.name_prefix
  environment = var.environment
}

# ── EFS (Kafka log persistence) ───────────────────────────────────────────────
module "efs_kafka" {
  source = "./modules/efs"

  name_prefix        = local.name_prefix
  environment        = var.environment
  vpc_id             = module.networking.vpc_id
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_ids = [module.networking.ecs_sg_id]
}

# ── Kafka on ECS (KRaft) ──────────────────────────────────────────────────────
module "ecs_kafka" {
  source = "./modules/ecs_kafka"

  name_prefix          = local.name_prefix
  environment          = var.environment
  cluster_id           = module.ecs.cluster_id
  cluster_arn          = module.ecs.cluster_arn
  private_subnet_ids   = module.networking.private_subnet_ids
  security_group_ids   = [module.networking.ecs_sg_id]
  execution_role_arn   = module.iam.ecs_execution_role_arn
  task_role_arn        = module.iam.ecs_task_role_arn
  kafka_image          = "${module.ecr.repository_urls["kafka"]}:latest"
  efs_file_system_id   = module.efs_kafka.file_system_id
  efs_access_point_id  = module.efs_kafka.access_point_id
  service_discovery_namespace_id   = module.networking.service_discovery_namespace_id
  service_discovery_namespace_name = module.networking.service_discovery_namespace_name
  cpu                  = 2048   # 2 vCPU
  memory               = 4096   # 4 GB
}

# ── Kafka Connect on ECS ──────────────────────────────────────────────────────
module "ecs_kafka_connect" {
  source = "./modules/ecs_kafka_connect"

  name_prefix          = local.name_prefix
  environment          = var.environment
  cluster_id           = module.ecs.cluster_id
  cluster_arn          = module.ecs.cluster_arn
  private_subnet_ids   = module.networking.private_subnet_ids
  security_group_ids   = [module.networking.ecs_sg_id]
  execution_role_arn   = module.iam.ecs_execution_role_arn
  task_role_arn        = module.iam.ecs_task_role_arn
  connect_image        = "${module.ecr.repository_urls["kafka-connect"]}:latest"
  kafka_bootstrap      = "${module.ecs_kafka.service_discovery_endpoint}:9092"
  s3_processed_bucket  = module.s3.processed_bucket_name
  s3_region            = var.aws_region
  service_discovery_namespace_id   = module.networking.service_discovery_namespace_id
  service_discovery_namespace_name = module.networking.service_discovery_namespace_name
  cpu                  = 512    # 0.5 vCPU
  memory               = 1024   # 1 GB
}

# ── Flink JobManager on ECS ───────────────────────────────────────────────────
module "ecs_flink_jobmanager" {
  source = "./modules/ecs_flink"

  name_prefix        = local.name_prefix
  environment        = var.environment
  role               = "jobmanager"
  cluster_id         = module.ecs.cluster_id
  cluster_arn        = module.ecs.cluster_arn
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_ids = [module.networking.ecs_sg_id]
  execution_role_arn = module.iam.ecs_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn
  flink_image        = "${module.ecr.repository_urls["flink-jobmanager"]}:latest"
  kafka_bootstrap    = "${module.ecs_kafka.service_discovery_endpoint}:9092"
  service_discovery_namespace_id   = module.networking.service_discovery_namespace_id
  service_discovery_namespace_name = module.networking.service_discovery_namespace_name
  cpu                = 1024   # 1 vCPU
  memory             = 2048   # 2 GB
}

# ── Flink TaskManager on ECS ──────────────────────────────────────────────────
module "ecs_flink_taskmanager" {
  source = "./modules/ecs_flink"

  name_prefix        = local.name_prefix
  environment        = var.environment
  role               = "taskmanager"
  cluster_id         = module.ecs.cluster_id
  cluster_arn        = module.ecs.cluster_arn
  private_subnet_ids = module.networking.private_subnet_ids
  security_group_ids = [module.networking.ecs_sg_id]
  execution_role_arn = module.iam.ecs_execution_role_arn
  task_role_arn      = module.iam.ecs_task_role_arn
  flink_image        = "${module.ecr.repository_urls["flink-taskmanager"]}:latest"
  kafka_bootstrap    = "${module.ecs_kafka.service_discovery_endpoint}:9092"
  jobmanager_host    = module.ecs_flink_jobmanager.service_discovery_endpoint
  service_discovery_namespace_id   = module.networking.service_discovery_namespace_id
  service_discovery_namespace_name = module.networking.service_discovery_namespace_name
  cpu                = 2048   # 2 vCPU
  memory             = 4096   # 4 GB
}

# ── Lambda: Producer (self-invoking tick loop) ────────────────────────────────
module "lambda_producer" {
  source = "./modules/lambda"

  name_prefix         = local.name_prefix
  function_name       = "producer"
  environment         = var.environment
  lambda_role_arn     = module.iam.lambda_role_arn
  timeout             = 10
  source_dir          = "${path.root}/../lambda/producer"
  dynamodb_table_name = module.dynamodb.table_name
  private_subnet_ids  = module.networking.private_subnet_ids
  security_group_ids  = [module.networking.lambda_sg_id]
  extra_env_vars = {
    KAFKA_BOOTSTRAP_SERVERS = "${module.ecs_kafka.service_discovery_endpoint}:9092"
    TOTAL_TICKS             = "70"
    TICK_INTERVAL_S         = "1.0"
    TEARDOWN_LAMBDA_ARN     = module.lambda_teardown.function_arn
    PRODUCER_LAMBDA_ARN     = ""   # resolved at runtime via context.invoked_function_arn
  }

  # Producer self-invokes 70x — bypass Lambda's 16-iteration recursive loop detection
  allow_recursive_loop = true
}

# ── Lambda: Controller (start ECS, kick off producer loop) ───────────────────
module "lambda_controller" {
  source = "./modules/lambda"

  name_prefix         = local.name_prefix
  function_name       = "controller"
  environment         = var.environment
  lambda_role_arn     = module.iam.lambda_role_arn
  timeout             = 180
  source_dir          = "${path.root}/../lambda/controller"
  dynamodb_table_name = module.dynamodb.table_name
  private_subnet_ids  = module.networking.private_subnet_ids
  security_group_ids  = [module.networking.lambda_sg_id]
  extra_env_vars = {
    ECS_CLUSTER         = module.ecs.cluster_name
    ECS_SERVICES        = jsonencode([
      module.ecs_kafka.service_name,
      module.ecs_kafka_connect.service_name,
      module.ecs_flink_jobmanager.service_name,
      module.ecs_flink_taskmanager.service_name,
    ])
    PRODUCER_LAMBDA_ARN = module.lambda_producer.function_arn
    TOTAL_TICKS         = "70"
    ECS_READY_TIMEOUT   = "120"
  }
}

# ── Lambda: Teardown (stop ECS, trigger Glue) ─────────────────────────────────
module "lambda_teardown" {
  source = "./modules/lambda"

  name_prefix         = local.name_prefix
  function_name       = "teardown"
  environment         = var.environment
  lambda_role_arn     = module.iam.lambda_role_arn
  timeout             = 120
  source_dir          = "${path.root}/../lambda/teardown"
  dynamodb_table_name = module.dynamodb.table_name
  private_subnet_ids  = module.networking.private_subnet_ids
  security_group_ids  = [module.networking.lambda_sg_id]
  extra_env_vars = {
    ECS_CLUSTER        = module.ecs.cluster_name
    ECS_SERVICES       = jsonencode([
      module.ecs_kafka.service_name,
      module.ecs_kafka_connect.service_name,
      module.ecs_flink_jobmanager.service_name,
      module.ecs_flink_taskmanager.service_name,
    ])
    GLUE_JOB_NAME      = module.glue.job_name
    FLUSH_GRACE_PERIOD  = "60"
  }
}

# ── Lambda: Status (dashboard polling endpoint) ───────────────────────────────
module "lambda_status" {
  source = "./modules/lambda"

  name_prefix         = local.name_prefix
  function_name       = "status"
  environment         = var.environment
  lambda_role_arn     = module.iam.lambda_role_arn
  timeout             = 10
  source_dir          = "${path.root}/../lambda/status"
  dynamodb_table_name = module.dynamodb.table_name
  private_subnet_ids  = module.networking.private_subnet_ids
  security_group_ids  = [module.networking.lambda_sg_id]
  extra_env_vars      = {}
}

# ── Glue ETL ──────────────────────────────────────────────────────────────────
module "glue" {
  source = "./modules/glue"

  name_prefix         = local.name_prefix
  environment         = var.environment
  glue_role_arn       = module.iam.glue_role_arn
  s3_processed_bucket = module.s3.processed_bucket_name
  s3_curated_bucket   = module.s3.curated_bucket_name
  s3_scripts_bucket   = module.s3.scripts_bucket_name
  glue_database       = "${local.name_prefix}-db"
}

# ── SNS Alerts Topic ──────────────────────────────────────────────────────────
module "sns" {
  source = "./modules/sns"

  name_prefix  = local.name_prefix
  environment  = var.environment
  alert_emails = var.alert_emails
}

# ── API Gateway (event-driven pipeline control) ───────────────────────────────
module "api_gateway" {
  source = "./modules/api_gateway"

  name_prefix                    = local.name_prefix
  environment                    = var.environment
  controller_lambda_invoke_arn   = module.lambda_controller.invoke_arn
  controller_lambda_function_name = module.lambda_controller.function_name
  status_lambda_invoke_arn       = module.lambda_status.invoke_arn
  status_lambda_function_name    = module.lambda_status.function_name
  teardown_lambda_invoke_arn     = module.lambda_teardown.invoke_arn
  teardown_lambda_function_name  = module.lambda_teardown.function_name
}

# ── S3 Dashboard Hosting ──────────────────────────────────────────────────────
module "dashboard" {
  source = "./modules/dashboard"

  name_prefix   = local.name_prefix
  environment   = var.environment
  api_base_url  = module.api_gateway.api_url
}

# ── GitHub OIDC (CI/CD) ───────────────────────────────────────────────────────
module "github_oidc" {
  source = "./modules/github_oidc"

  name_prefix  = local.name_prefix
  environment  = var.environment
  github_org   = var.github_org
  github_repo  = var.github_repo
}
