###############################################################################
# Outputs — Glue Module
###############################################################################

output "job_name" {
  value = aws_glue_job.curated_layer.name
}

output "database_name" {
  value = aws_glue_catalog_database.pipeline.name
}
