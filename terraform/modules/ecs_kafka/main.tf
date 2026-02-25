###############################################################################
# ECS Kafka — KRaft Single-Node Broker on Fargate
###############################################################################

# ── CloudWatch Log Group ─────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "kafka" {
  name              = "/ecs/${var.name_prefix}-kafka"
  retention_in_days = 7
}

# ── Service Discovery ────────────────────────────────────────────────────
resource "aws_service_discovery_service" "kafka" {
  name = "kafka"

  dns_config {
    namespace_id = var.service_discovery_namespace_id

    dns_records {
      ttl  = 10
      type = "A"
    }

    routing_policy = "MULTIVALUE"
  }
}

# ── Task Definition ──────────────────────────────────────────────────────
resource "aws_ecs_task_definition" "kafka" {
  family                   = "${var.name_prefix}-kafka"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  volume {
    name = "kafka-data"

    efs_volume_configuration {
      file_system_id     = var.efs_file_system_id
      transit_encryption = "ENABLED"

      authorization_config {
        access_point_id = var.efs_access_point_id
        iam             = "ENABLED"
      }
    }
  }

  container_definitions = jsonencode([{
    name      = "kafka"
    image     = var.kafka_image
    essential = true

    portMappings = [
      { containerPort = 9092, protocol = "tcp" },
      { containerPort = 9093, protocol = "tcp" },
    ]

    mountPoints = [{
      sourceVolume  = "kafka-data"
      containerPath = "/var/kafka/data"
      readOnly      = false
    }]

    environment = [
      {
        name  = "KAFKA_ADVERTISED_LISTENERS"
        value = "PLAINTEXT://kafka.${var.service_discovery_namespace_name}:9092"
      },
      {
        name  = "KAFKA_TOPICS"
        value = "raw-ticks:3:1,enriched-ticks:3:1,vwap-ticks:3:1,alerts:1:1"
      },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.kafka.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "kafka"
      }
    }
  }])
}

# ── ECS Service ──────────────────────────────────────────────────────────
resource "aws_ecs_service" "kafka" {
  name            = "${var.name_prefix}-kafka"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.kafka.arn
  desired_count   = 0
  launch_type     = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.kafka.arn
  }

  # Allow Controller Lambda to change desired_count without drift
  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── Data Sources ─────────────────────────────────────────────────────────
data "aws_region" "current" {}
