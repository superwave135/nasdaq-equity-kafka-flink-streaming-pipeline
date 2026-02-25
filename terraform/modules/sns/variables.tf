###############################################################################
# Variables — SNS Module
###############################################################################

variable "name_prefix" { type = string }
variable "environment" { type = string }

variable "alert_emails" {
  description = "List of email addresses to receive alerts"
  type        = list(string)
  default     = []
}
