###############################################################################
# Lambda — Reusable module for all pipeline functions
# Used 4×: producer, controller, teardown, status
###############################################################################

# ── CloudWatch Log Group ─────────────────────────────────────────────────
resource "aws_cloudwatch_log_group" "function" {
  name              = "/aws/lambda/${var.name_prefix}-${var.function_name}"
  retention_in_days = 14
}

# ── Deployment Package (pip install + zip) ─────────────────────────────
# Install pip dependencies into a build directory, then zip.
# terraform_data triggers rebuild when handler.py or requirements.txt change.
resource "terraform_data" "pip_install" {
  triggers_replace = [
    filemd5("${var.source_dir}/handler.py"),
    filemd5("${var.source_dir}/requirements.txt"),
  ]

  provisioner "local-exec" {
    command = <<-EOT
      set -e
      BUILD_DIR="${path.module}/.build/${var.function_name}/package"
      rm -rf "$BUILD_DIR"
      mkdir -p "$BUILD_DIR"
      cp "${var.source_dir}"/*.py "$BUILD_DIR/"
      pip3 install -r "${var.source_dir}/requirements.txt" \
        -t "$BUILD_DIR/" --quiet --upgrade
    EOT
  }
}

data "archive_file" "function" {
  type        = "zip"
  source_dir  = "${path.module}/.build/${var.function_name}/package"
  output_path = "${path.module}/.build/${var.function_name}.zip"
  depends_on  = [terraform_data.pip_install]
}

# ── Lambda Function ──────────────────────────────────────────────────────
resource "aws_lambda_function" "function" {
  function_name    = "${var.name_prefix}-${var.function_name}"
  role             = var.lambda_role_arn
  handler          = "handler.lambda_handler"
  runtime          = "python3.12"
  timeout          = var.timeout
  memory_size      = var.memory_size
  filename         = data.archive_file.function.output_path
  source_code_hash = data.archive_file.function.output_base64sha256

  vpc_config {
    subnet_ids         = var.private_subnet_ids
    security_group_ids = var.security_group_ids
  }

  environment {
    variables = merge(
      {
        DYNAMODB_TABLE = var.dynamodb_table_name
        ENVIRONMENT    = var.environment
      },
      var.extra_env_vars,
    )
  }

  depends_on = [aws_cloudwatch_log_group.function]
}

# ── Recursive Loop Config (producer self-invocation) ───────────────
# AWS Lambda stops self-invoking chains after 16 iterations by default.
# The producer tick loop needs 60 iterations, so allow recursive calls.
resource "aws_lambda_function_recursion_config" "allow" {
  count         = var.allow_recursive_loop ? 1 : 0
  function_name = aws_lambda_function.function.function_name
  recursive_loop = "Allow"
}
