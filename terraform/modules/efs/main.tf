###############################################################################
# EFS — Persistent Volume for Kafka Logs
###############################################################################

resource "aws_efs_file_system" "main" {
  creation_token = "${var.name_prefix}-kafka-data"
  encrypted      = true

  performance_mode = "generalPurpose"
  throughput_mode  = "bursting"

  tags = { Name = "${var.name_prefix}-kafka-data" }
}

# Mount target in each private subnet
resource "aws_efs_mount_target" "private" {
  count           = 2  # matches len(availability_zones) in terraform.tfvars; avoids module-output chicken-and-egg during imports
  file_system_id  = aws_efs_file_system.main.id
  subnet_id       = var.private_subnet_ids[count.index]
  security_groups = var.security_group_ids
}

# Access point for Kafka container (uid/gid 1000 = kafka user)
resource "aws_efs_access_point" "kafka" {
  file_system_id = aws_efs_file_system.main.id

  posix_user {
    uid = 1000
    gid = 1000
  }

  root_directory {
    path = "/kafka-data"

    creation_info {
      owner_uid   = 1000
      owner_gid   = 1000
      permissions = "0755"
    }
  }

  tags = { Name = "${var.name_prefix}-kafka-ap" }
}
