# Startup Guide

Step-by-step instructions to deploy and run the nasdaq-stock-streaming-pipeline from scratch.

---

## 1. Prerequisites

Install these before starting:

| Tool | Version | Check |
|---|---|---|
| AWS CLI | v2 | `aws --version` |
| Terraform | >= 1.5 | `terraform --version` |
| Docker | 20+ | `docker --version` |
| Python | 3.11+ | `python3 --version` |
| Git | any | `git --version` |

You also need:
- An AWS account with admin-level permissions (or scoped IAM user)
- An S3 bucket for Terraform remote state (create one manually if you don't have it)
- AWS CLI configured with credentials: `aws configure` or SSO

---

## 2. Clone the Repository

```bash
git clone https://github.com/YOUR_GITHUB_USERNAME/nasdaq-stock-streaming-pipeline.git
cd nasdaq-stock-streaming-pipeline
```

---

## 3. Configure Terraform Variables

Edit `terraform/envs/dev/terraform.tfvars` with your values:

```hcl
aws_region   = "ap-southeast-1"
project_name = "stock-streaming"
environment  = "dev"
owner        = "<your-github-username>"

vpc_cidr           = "10.0.0.0/16"
availability_zones = ["ap-southeast-1a", "ap-southeast-1b"]

alert_emails = ["your-email@example.com"]

github_org  = "<your-github-username>"
github_repo = "nasdaq-stock-streaming-pipeline"
```

---

## 4. Initialize and Deploy Terraform

```bash
cd terraform

# Initialize with your state bucket
terraform init \
  -backend-config="bucket=<your-tf-state-bucket>" \
  -backend-config="region=ap-southeast-1"

# Preview changes
terraform plan -var-file=envs/dev/terraform.tfvars

# Deploy (creates VPC, ECS cluster, DynamoDB, Lambda, API Gateway, etc.)
terraform apply -var-file=envs/dev/terraform.tfvars
```

This creates all infrastructure but ECS services start at `desiredCount=0` (idle).

Save the outputs — you'll need `api_base_url` and `ecr_repository_urls`:

```bash
terraform output
```

---

## 5. Build and Push Docker Images

There are 4 container images to build. From the project root:

```bash
# Login to ECR
aws ecr get-login-password --region ap-southeast-1 | \
  docker login --username AWS --password-stdin \
  <account-id>.dkr.ecr.ap-southeast-1.amazonaws.com

# Get the ECR registry prefix
ECR_REGISTRY="<account-id>.dkr.ecr.ap-southeast-1.amazonaws.com"
PREFIX="stock-streaming-dev"

# Build and push each image
for SERVICE in kafka kafka-connect flink-jobmanager flink-taskmanager; do
  docker build -t $ECR_REGISTRY/$PREFIX-$SERVICE:latest -f docker/$SERVICE/Dockerfile .
  docker push $ECR_REGISTRY/$PREFIX-$SERVICE:latest
done
```

Alternatively, push to `main` and let GitHub Actions CI/CD handle this automatically (see Step 8).

---

## 6. Upload Glue Script

```bash
S3_SCRIPTS_BUCKET=$(cd terraform && terraform output -raw s3_scripts_bucket)
aws s3 cp glue/jobs/curated_layer_builder.py \
  s3://$S3_SCRIPTS_BUCKET/glue/curated_layer_builder.py
```

---

## 7. Confirm SNS Subscription

If you added `alert_emails` in Step 3, check your inbox and **confirm the SNS subscription** email from AWS. Without this, anomaly alerts won't be delivered.

---

## 8. (Optional) Set Up GitHub Actions CI/CD

For automated deploys on push to `main`:

1. In your GitHub repo, go to **Settings > Secrets and variables > Actions**
2. Add these repository secrets:

| Secret | Value |
|---|---|
| `AWS_ACCOUNT_ID` | Your 12-digit AWS account ID |
| `AWS_GITHUB_ACTIONS_ROLE_ARN` | From `terraform output github_actions_role_arn` |
| `TF_STATE_BUCKET` | Your Terraform state bucket name |

3. Create a **GitHub Environment** called `dev` with required reviewers (for manual approval on `terraform apply`)

After this, every push to `main` will: lint, test, build images, plan, and (after approval) apply.

---

## 9. Start the Pipeline

### Option A: Dashboard

Open the dashboard URL in your browser:

```bash
cd terraform && terraform output -raw dashboard_url
```

Click **[START PIPELINE]**. The dashboard polls status every 2 seconds automatically.

### Option B: CLI

```bash
# Start
curl -X POST $(cd terraform && terraform output -raw api_start_url)

# Watch progress (polls every 2s)
watch -n 2 "curl -s $(cd terraform && terraform output -raw api_status_url) | python3 -m json.tool"
```

### What happens when you start:

1. Controller Lambda starts all 4 ECS services (~30s to stabilize)
2. Producer Lambda begins the tick loop (60 ticks, ~1s apart)
3. Each tick publishes 5 stock prices to Kafka
4. Flink processes in real-time (VWAP, anomaly detection, enrichment)
5. Kafka Connect writes processed data to S3
6. After tick 60, Teardown Lambda stops ECS and triggers Glue ETL
7. Glue writes Parquet tables to S3 curated zone

Total runtime: ~3 minutes (30s startup + 60s ticks + 60s flush + teardown + Glue).

---

## 10. Stop the Pipeline (Manual)

If you need to stop mid-run:

```bash
curl -X DELETE $(cd terraform && terraform output -raw api_stop_url)
```

Or click **[STOP]** on the dashboard. This sets ECS `desiredCount=0` and marks the run as `STOPPED` (skips Glue ETL).

---

## 11. Query Results in Athena

After the Glue ETL job completes (~5 minutes after pipeline finishes):

1. Open the **Athena console** in `ap-southeast-1`
2. Select database: `stock-streaming-dev-db`
3. Run the Glue Crawler first if tables aren't visible:
   ```bash
   aws glue start-crawler --name stock-streaming-dev-curated-crawler
   ```
4. Query:

```sql
-- Daily summary per symbol
SELECT * FROM agg_daily_summary ORDER BY symbol;

-- All anomaly alerts
SELECT * FROM agg_alerts ORDER BY alert_timestamp;

-- Raw enriched ticks
SELECT symbol, price_usd, volume, spread_bps
FROM fact_tick_events
WHERE symbol = 'NVDA'
ORDER BY event_timestamp;

-- VWAP candles
SELECT symbol, vwap_usd, high_usd, low_usd, total_volume
FROM fact_vwap
ORDER BY symbol, window_start_ts;
```

---

## 12. Running Tests Locally

```bash
pip install -r lambda/producer/requirements.txt
pip install pytest pytest-mock flake8

# Unit tests
pytest tests/ -v

# Lint
flake8 lambda/ flink/ glue/ --max-line-length=120 --ignore=E501,W503
```

---

## 13. Tear Down Everything

To destroy all AWS resources and stop incurring costs:

```bash
cd terraform
terraform destroy -var-file=envs/dev/terraform.tfvars
```

Manually delete if needed:
- Terraform state S3 bucket (not managed by this project)
- ECR images (Terraform destroys repos but `force_delete` may need to be set)
- CloudWatch log groups (may persist after destroy)

---

## Troubleshooting

| Issue | Fix |
|---|---|
| `409 Conflict` on start | A run is already active. Wait for it to finish or call DELETE `/pipeline/stop` |
| ECS services fail to stabilize | Check CloudWatch logs for the ECS tasks. Common: image not pushed to ECR yet |
| Kafka Connect not writing to S3 | Verify the S3 sink connector config. Check Kafka Connect logs in CloudWatch |
| Flink not processing | Check Flink JobManager logs. Ensure TaskManager is running and connected |
| Glue ETL fails | Check Glue job run logs in CloudWatch. Verify S3 processed zone has data |
| Dashboard shows "IDLE" forever | Verify `API_BASE` URL in `dashboard/index.html` matches `terraform output api_base_url` |
| Lambda timeout | Controller has 180s timeout — if ECS takes >120s to stabilize, increase `ECS_READY_TIMEOUT` |
| No SNS alerts received | Confirm the SNS email subscription (Step 7) |

---

## Cost Reference

With 1 run/day in `ap-southeast-1`, expect ~$6.45/month. See [README.md](README.md#monthly-cost-estimate-645) for the full breakdown. All ECS services idle at zero cost between runs.
