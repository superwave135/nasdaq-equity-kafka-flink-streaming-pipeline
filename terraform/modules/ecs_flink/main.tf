###############################################################################
# ECS Flink — Shared module for JobManager and TaskManager
# Instantiated twice from root: role=jobmanager and role=taskmanager
###############################################################################

# ── CloudWatch Log Group ─────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "flink" {
  name              = "/ecs/${var.name_prefix}-flink-${var.role}"
  retention_in_days = 7
}

# ── Service Discovery ────────────────────────────────────────────────────
resource "aws_service_discovery_service" "flink" {
  name = "flink-${var.role}"

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

# ── Environment Variables ────────────────────────────────────────────────
locals {
  common_env = [
    { name = "KAFKA_BOOTSTRAP_SERVERS", value = var.kafka_bootstrap },
  ]

  jobmanager_env = [
    { name = "FLINK_PROPERTIES", value = join("\n", [
      "jobmanager.rpc.address: flink-${var.role}.${var.service_discovery_namespace_name}",
      "jobmanager.bind-host: 0.0.0.0",
      "jobmanager.rpc.port: 6123",
      "jobmanager.memory.process.size: ${var.memory}m",
      "jobmanager.execution.failover-strategy: region",
      "rest.port: 8081",
      "rest.address: 0.0.0.0",
      "rest.bind-address: 0.0.0.0",
      "parallelism.default: 1",
      "taskmanager.numberOfTaskSlots: 2",
    ]) },
  ]

  taskmanager_env = [
    { name = "FLINK_PROPERTIES", value = join("\n", [
      "jobmanager.rpc.address: ${var.jobmanager_host}",
      "jobmanager.rpc.port: 6123",
      "taskmanager.bind-host: 0.0.0.0",
      "taskmanager.memory.process.size: ${var.memory}m",
      "taskmanager.numberOfTaskSlots: 2",
    ]) },
  ]

  env_vars = concat(
    local.common_env,
    var.role == "jobmanager" ? local.jobmanager_env : local.taskmanager_env,
  )

  port_mappings = var.role == "jobmanager" ? [
    { containerPort = 8081, protocol = "tcp" },
    { containerPort = 6123, protocol = "tcp" },
    { containerPort = 6124, protocol = "tcp" },
  ] : [
    { containerPort = 6121, protocol = "tcp" },
    { containerPort = 6122, protocol = "tcp" },
  ]
}

# ── Task Definition ──────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "flink" {
  family                   = "${var.name_prefix}-flink-${var.role}"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "flink-${var.role}"
    image     = var.flink_image
    essential = true

    command = [var.role]

    portMappings = local.port_mappings
    environment  = local.env_vars

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.flink.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "flink-${var.role}"
      }
    }
  }])
}

# ── ECS Service ──────────────────────────────────────────────────────────
resource "aws_ecs_service" "flink" {
  name            = "${var.name_prefix}-flink-${var.role}"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.flink.arn
  desired_count   = 0
  launch_type     = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.flink.arn
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── Data Sources ─────────────────────────────────────────────────────────
data "aws_region" "current" {}
