###############################################################################
# Glue — ETL Job, Database, Scripts Upload
###############################################################################

# ── Glue Data Catalog Database ───────────────────────────────────────────
resource "aws_glue_catalog_database" "pipeline" {
  name = var.glue_database
}

# ── Upload ETL Script to S3 ─────────────────────────────────────────────
resource "aws_s3_object" "glue_script" {
  bucket = var.s3_scripts_bucket
  key    = "glue/curated_layer_builder.py"
  source = "${path.module}/../../../glue/jobs/curated_layer_builder.py"
  etag   = filemd5("${path.module}/../../../glue/jobs/curated_layer_builder.py")
}

# ── Glue ETL Job ─────────────────────────────────────────────────────────
resource "aws_glue_job" "curated_layer" {
  name     = "${var.name_prefix}-curated-layer-builder"
  role_arn = var.glue_role_arn

  command {
    name            = "glueetl"
    script_location = "s3://${var.s3_scripts_bucket}/glue/curated_layer_builder.py"
    python_version  = "3"
  }

  default_arguments = {
    "--job-language"               = "python"
    "--job-bookmark-option"        = "job-bookmark-enable"
    "--enable-metrics"             = "true"
    "--enable-continuous-cloudwatch-log" = "true"
    "--S3_PROCESSED_BUCKET"        = var.s3_processed_bucket
    "--S3_CURATED_BUCKET"          = var.s3_curated_bucket
    "--GLUE_DATABASE"              = var.glue_database
    "--TempDir"                    = "s3://${var.s3_scripts_bucket}/glue/temp/"
  }

  glue_version      = "4.0"
  number_of_workers = 2
  worker_type       = "G.1X"
  timeout           = 30
  max_retries       = 0

  tags = { Name = "${var.name_prefix}-curated-layer-builder" }
}

# ── Glue Crawler (discovers curated zone tables) ────────────────────────
resource "aws_glue_crawler" "curated" {
  name          = "${var.name_prefix}-curated-crawler"
  database_name = aws_glue_catalog_database.pipeline.name
  role          = var.glue_role_arn

  s3_target {
    path = "s3://${var.s3_curated_bucket}/"
  }

  schema_change_policy {
    update_behavior = "UPDATE_IN_DATABASE"
    delete_behavior = "LOG"
  }

  tags = { Name = "${var.name_prefix}-curated-crawler" }
}
