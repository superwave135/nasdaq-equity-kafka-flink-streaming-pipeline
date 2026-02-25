output "api_url" {
  description = "Base URL for the pipeline REST API"
  value       = aws_api_gateway_stage.dev.invoke_url
}

output "api_start_url" {
  description = "POST endpoint to start the pipeline"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/pipeline/start"
}

output "api_status_url" {
  description = "GET endpoint to check pipeline status"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/pipeline/status"
}

output "api_stop_url" {
  description = "DELETE endpoint to stop the pipeline"
  value       = "${aws_api_gateway_stage.dev.invoke_url}/pipeline/stop"
}
