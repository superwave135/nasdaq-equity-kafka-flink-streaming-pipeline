###############################################################################
# Networking — VPC, Subnets, NAT, Security Groups, Service Discovery
###############################################################################

# ── VPC ─────────────────────────────────────────────────────────────────────
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  tags = { Name = "${var.name_prefix}-vpc" }
}

# ── Internet Gateway ───────────────────────────────────────────────────────
resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-igw" }
}

# ── Public Subnets (one per AZ — host NAT gateway) ────────────────────────
resource "aws_subnet" "public" {
  count                   = length(var.availability_zones)
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(var.vpc_cidr, 8, count.index)
  availability_zone       = var.availability_zones[count.index]
  map_public_ip_on_launch = true

  tags = { Name = "${var.name_prefix}-public-${var.availability_zones[count.index]}" }
}

# ── Private Subnets (one per AZ — ECS services + Lambda) ─────────────────
resource "aws_subnet" "private" {
  count             = length(var.availability_zones)
  vpc_id            = aws_vpc.main.id
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, count.index + 100)
  availability_zone = var.availability_zones[count.index]

  tags = { Name = "${var.name_prefix}-private-${var.availability_zones[count.index]}" }
}

# ── NAT Gateway (single, in first public subnet — cost-effective for dev) ─
resource "aws_eip" "nat" {
  domain = "vpc"

  tags = { Name = "${var.name_prefix}-nat-eip" }
}

resource "aws_nat_gateway" "main" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[0].id

  tags = { Name = "${var.name_prefix}-nat" }

  depends_on = [aws_internet_gateway.main]
}

# ── Route Tables ───────────────────────────────────────────────────────────
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-public-rt" }
}

resource "aws_route_table_association" "public" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.main.id
  }

  tags = { Name = "${var.name_prefix}-private-rt" }
}

resource "aws_route_table_association" "private" {
  count          = length(var.availability_zones)
  subnet_id      = aws_subnet.private[count.index].id
  route_table_id = aws_route_table.private.id
}

# ── Security Group: ECS Services ──────────────────────────────────────────
# Kafka, Kafka Connect, Flink — all inter-communicate within this SG.
resource "aws_security_group" "ecs" {
  name        = "${var.name_prefix}-ecs-sg"
  description = "ECS services (Kafka, Connect, Flink) - inter-service traffic"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-ecs-sg" }
}

# Self-referencing: ECS services talk to each other on any port
resource "aws_vpc_security_group_ingress_rule" "ecs_self" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.ecs.id
  ip_protocol                  = "-1"
  description                  = "Allow all traffic between ECS services"
}

# Lambda → ECS: allow Lambda to reach Kafka broker (port 9092)
resource "aws_vpc_security_group_ingress_rule" "ecs_from_lambda" {
  security_group_id            = aws_security_group.ecs.id
  referenced_security_group_id = aws_security_group.lambda.id
  ip_protocol                  = "tcp"
  from_port                    = 9092
  to_port                      = 9092
  description                  = "Lambda producer to Kafka broker"
}

# ECS egress: allow all outbound (ECR, CloudWatch, S3, etc.)
resource "aws_vpc_security_group_egress_rule" "ecs_all_out" {
  security_group_id = aws_security_group.ecs.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound"
}

# ── Security Group: Lambda Functions ──────────────────────────────────────
# Producer, Controller, Teardown, Status — VPC-attached Lambdas.
resource "aws_security_group" "lambda" {
  name        = "${var.name_prefix}-lambda-sg"
  description = "Lambda functions - outbound to Kafka and AWS services"
  vpc_id      = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-lambda-sg" }
}

# Lambda egress: allow all outbound (Kafka via VPC, AWS APIs via NAT)
resource "aws_vpc_security_group_egress_rule" "lambda_all_out" {
  security_group_id = aws_security_group.lambda.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  description       = "Allow all outbound"
}

# ── Service Discovery Namespace (Cloud Map) ───────────────────────────────
# ECS services register here for internal DNS resolution within the VPC.
# e.g., kafka.stock-streaming.local → Kafka broker container IP
resource "aws_service_discovery_private_dns_namespace" "main" {
  name        = "${var.name_prefix}.local"
  description = "Service discovery for ${var.name_prefix} ECS services"
  vpc         = aws_vpc.main.id

  tags = { Name = "${var.name_prefix}-sd-namespace" }
}
