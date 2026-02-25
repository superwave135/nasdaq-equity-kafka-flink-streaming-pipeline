###############################################################################
# SNS — Alert Topic for Pipeline Anomalies
###############################################################################

resource "aws_sns_topic" "alerts" {
  name = "${var.name_prefix}-alerts"

  tags = { Name = "${var.name_prefix}-alerts" }
}

resource "aws_sns_topic_subscription" "email" {
  count     = length(var.alert_emails)
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_emails[count.index]
}
