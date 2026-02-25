variable "name_prefix"                     { type = string }
variable "environment"                      { type = string }
variable "controller_lambda_invoke_arn"     { type = string }
variable "controller_lambda_function_name"  { type = string }
variable "status_lambda_invoke_arn"         { type = string }
variable "status_lambda_function_name"      { type = string }
variable "teardown_lambda_invoke_arn"       { type = string }
variable "teardown_lambda_function_name"    { type = string }
