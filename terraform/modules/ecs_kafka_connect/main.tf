###############################################################################
# ECS Kafka Connect — S3 Sink Connector on Fargate
###############################################################################

# ── CloudWatch Log Group ─────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "connect" {
  name              = "/ecs/${var.name_prefix}-kafka-connect"
  retention_in_days = 7
}

# ── Service Discovery ────────────────────────────────────────────────────
resource "aws_service_discovery_service" "connect" {
  name = "kafka-connect"

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
resource "aws_ecs_task_definition" "connect" {
  family                   = "${var.name_prefix}-kafka-connect"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = var.execution_role_arn
  task_role_arn            = var.task_role_arn

  container_definitions = jsonencode([{
    name      = "kafka-connect"
    image     = var.connect_image
    essential = true

    portMappings = [
      { containerPort = 8083, protocol = "tcp" },
    ]

    environment = [
      { name = "CONNECT_BOOTSTRAP_SERVERS",                value = var.kafka_bootstrap },
      { name = "CONNECT_GROUP_ID",                         value = "${var.name_prefix}-connect" },
      { name = "CONNECT_CONFIG_STORAGE_TOPIC",             value = "connect-configs" },
      { name = "CONNECT_OFFSET_STORAGE_TOPIC",             value = "connect-offsets" },
      { name = "CONNECT_STATUS_STORAGE_TOPIC",             value = "connect-status" },
      { name = "CONNECT_CONFIG_STORAGE_REPLICATION_FACTOR", value = "1" },
      { name = "CONNECT_OFFSET_STORAGE_REPLICATION_FACTOR", value = "1" },
      { name = "CONNECT_STATUS_STORAGE_REPLICATION_FACTOR", value = "1" },
      { name = "CONNECT_KEY_CONVERTER",                    value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_VALUE_CONVERTER",                  value = "org.apache.kafka.connect.json.JsonConverter" },
      { name = "CONNECT_KEY_CONVERTER_SCHEMAS_ENABLE",     value = "false" },
      { name = "CONNECT_VALUE_CONVERTER_SCHEMAS_ENABLE",   value = "false" },
      { name = "CONNECT_REST_PORT",                        value = "8083" },
      { name = "CONNECT_REST_ADVERTISED_HOST_NAME",        value = "kafka-connect.${var.service_discovery_namespace_name}" },
      { name = "S3_PROCESSED_BUCKET",                      value = var.s3_processed_bucket },
      { name = "S3_REGION",                                value = var.s3_region },
      { name = "CONNECT_PLUGIN_PATH",                      value = "/usr/share/confluent-hub-components" },
    ]

    logConfiguration = {
      logDriver = "awslogs"
      options = {
        "awslogs-group"         = aws_cloudwatch_log_group.connect.name
        "awslogs-region"        = data.aws_region.current.name
        "awslogs-stream-prefix" = "connect"
      }
    }
  }])
}

# ── ECS Service ──────────────────────────────────────────────────────────
resource "aws_ecs_service" "connect" {
  name            = "${var.name_prefix}-kafka-connect"
  cluster         = var.cluster_id
  task_definition = aws_ecs_task_definition.connect.arn
  desired_count   = 0
  launch_type     = "FARGATE"
  platform_version = "LATEST"

  network_configuration {
    subnets          = var.private_subnet_ids
    security_groups  = var.security_group_ids
    assign_public_ip = false
  }

  service_registries {
    registry_arn = aws_service_discovery_service.connect.arn
  }

  lifecycle {
    ignore_changes = [desired_count]
  }
}

# ── Data Sources ─────────────────────────────────────────────────────────
data "aws_region" "current" {}
