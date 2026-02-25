###############################################################################
# API Gateway — Stock Streaming Pipeline REST API
# Routes:
#   POST   /pipeline/start  → controller Lambda
#   GET    /pipeline/status → status Lambda
#   DELETE /pipeline/stop   → teardown Lambda
###############################################################################

resource "aws_api_gateway_rest_api" "pipeline" {
  name        = "${var.name_prefix}-api"
  description = "Stock Streaming Pipeline control API"

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

# ── /pipeline resource ────────────────────────────────────────────────────────
resource "aws_api_gateway_resource" "pipeline" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  parent_id   = aws_api_gateway_rest_api.pipeline.root_resource_id
  path_part   = "pipeline"
}

# ── /pipeline/start ───────────────────────────────────────────────────────────
resource "aws_api_gateway_resource" "start" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  parent_id   = aws_api_gateway_resource.pipeline.id
  path_part   = "start"
}

resource "aws_api_gateway_method" "start_post" {
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  resource_id   = aws_api_gateway_resource.start.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "start_post" {
  rest_api_id             = aws_api_gateway_rest_api.pipeline.id
  resource_id             = aws_api_gateway_resource.start.id
  http_method             = aws_api_gateway_method.start_post.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.controller_lambda_invoke_arn
}

# ── /pipeline/status ──────────────────────────────────────────────────────────
resource "aws_api_gateway_resource" "status" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  parent_id   = aws_api_gateway_resource.pipeline.id
  path_part   = "status"
}

resource "aws_api_gateway_method" "status_get" {
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  resource_id   = aws_api_gateway_resource.status.id
  http_method   = "GET"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "status_get" {
  rest_api_id             = aws_api_gateway_rest_api.pipeline.id
  resource_id             = aws_api_gateway_resource.status.id
  http_method             = aws_api_gateway_method.status_get.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.status_lambda_invoke_arn
}

# ── /pipeline/stop ────────────────────────────────────────────────────────────
resource "aws_api_gateway_resource" "stop" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  parent_id   = aws_api_gateway_resource.pipeline.id
  path_part   = "stop"
}

resource "aws_api_gateway_method" "stop_delete" {
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  resource_id   = aws_api_gateway_resource.stop.id
  http_method   = "DELETE"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "stop_delete" {
  rest_api_id             = aws_api_gateway_rest_api.pipeline.id
  resource_id             = aws_api_gateway_resource.stop.id
  http_method             = aws_api_gateway_method.stop_delete.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = var.teardown_lambda_invoke_arn
}

# ── CORS OPTIONS for all routes ───────────────────────────────────────────────
locals {
  cors_resources = {
    start  = aws_api_gateway_resource.start.id
    status = aws_api_gateway_resource.status.id
    stop   = aws_api_gateway_resource.stop.id
  }
}

resource "aws_api_gateway_method" "cors" {
  for_each      = local.cors_resources
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  resource_id   = each.value
  http_method   = "OPTIONS"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "cors" {
  for_each    = local.cors_resources
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  resource_id = each.value
  http_method = aws_api_gateway_method.cors[each.key].http_method
  type        = "MOCK"

  request_templates = {
    "application/json" = "{\"statusCode\": 200}"
  }
}

resource "aws_api_gateway_method_response" "cors" {
  for_each    = local.cors_resources
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  resource_id = each.value
  http_method = aws_api_gateway_method.cors[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = true
    "method.response.header.Access-Control-Allow-Methods" = true
    "method.response.header.Access-Control-Allow-Origin"  = true
  }
}

resource "aws_api_gateway_integration_response" "cors" {
  for_each    = local.cors_resources
  rest_api_id = aws_api_gateway_rest_api.pipeline.id
  resource_id = each.value
  http_method = aws_api_gateway_method.cors[each.key].http_method
  status_code = "200"

  response_parameters = {
    "method.response.header.Access-Control-Allow-Headers" = "'Content-Type,Authorization'"
    "method.response.header.Access-Control-Allow-Methods" = "'GET,POST,DELETE,OPTIONS'"
    "method.response.header.Access-Control-Allow-Origin"  = "'*'"
  }

  depends_on = [
    aws_api_gateway_integration.cors,
    aws_api_gateway_method_response.cors,
  ]
}

# ── Deployment & Stage ────────────────────────────────────────────────────────
resource "aws_api_gateway_deployment" "pipeline" {
  rest_api_id = aws_api_gateway_rest_api.pipeline.id

  # Force redeploy when routes change
  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_integration.start_post,
      aws_api_gateway_integration.status_get,
      aws_api_gateway_integration.stop_delete,
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }

  depends_on = [
    aws_api_gateway_integration.start_post,
    aws_api_gateway_integration.status_get,
    aws_api_gateway_integration.stop_delete,
  ]
}

# ── CloudWatch Logs role for API Gateway (account-level setting) ─────────────
resource "aws_iam_role" "api_gw_cloudwatch" {
  name = "${var.name_prefix}-api-gw-cloudwatch"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "apigateway.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "api_gw_cloudwatch" {
  role       = aws_iam_role.api_gw_cloudwatch.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonAPIGatewayPushToCloudWatchLogs"
}

resource "aws_api_gateway_account" "main" {
  cloudwatch_role_arn = aws_iam_role.api_gw_cloudwatch.arn

  depends_on = [aws_iam_role_policy_attachment.api_gw_cloudwatch]
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.pipeline.id
  rest_api_id   = aws_api_gateway_rest_api.pipeline.id
  stage_name    = var.environment

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gw.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      ip             = "$context.identity.sourceIp"
      httpMethod     = "$context.httpMethod"
      resourcePath   = "$context.resourcePath"
      status         = "$context.status"
      responseLength = "$context.responseLength"
    })
  }

  depends_on = [aws_api_gateway_account.main]
}

resource "aws_cloudwatch_log_group" "api_gw" {
  name              = "/aws/apigateway/${var.name_prefix}"
  retention_in_days = 7
}

# ── Lambda permissions ────────────────────────────────────────────────────────
resource "aws_lambda_permission" "controller" {
  statement_id  = "AllowAPIGatewayInvokeController"
  action        = "lambda:InvokeFunction"
  function_name = var.controller_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.pipeline.execution_arn}/*/*"
}

resource "aws_lambda_permission" "status" {
  statement_id  = "AllowAPIGatewayInvokeStatus"
  action        = "lambda:InvokeFunction"
  function_name = var.status_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.pipeline.execution_arn}/*/*"
}

resource "aws_lambda_permission" "teardown" {
  statement_id  = "AllowAPIGatewayInvokeTeardown"
  action        = "lambda:InvokeFunction"
  function_name = var.teardown_lambda_function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.pipeline.execution_arn}/*/*"
}

