# nasdaq-stock-streaming-pipeline

An **event-driven** real-time stock tick data streaming pipeline built on AWS. Triggered via a REST API or S3-hosted dashboard — starts Apache Kafka (KRaft) and Flink on ECS Fargate, runs a 60-second simulated tick feed (5 NASDAQ symbols, Geometric Brownian Motion pricing), then auto-tears down and triggers a Glue ETL job that builds a dimensional model queryable in Athena.

Built as a portfolio project to demonstrate real-time streaming architecture, event-driven design, and infrastructure-as-code on AWS.

## Dashboard URL
After deployment, your dashboard URL will be output by Terraform:
`http://<your-bucket-name>.s3-website-<region>.amazonaws.com/`

---

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│  TRIGGER LAYER                                              │
│                                                             │
│  Dashboard (S3)        curl -X POST .../pipeline/start      │
│  [Start Pipeline]  ──► API Gateway REST API                 │
└────────────────────────────┬────────────────────────────────┘
                             │ POST /pipeline/start
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  ORCHESTRATION LAYER                                        │
│                                                             │
│  Controller Lambda (timeout: 180s)                          │
│  ├── Idempotency check (DynamoDB run_state → 409 if active) │
│  ├── Start ECS: Kafka + Connect + Flink JM + Flink TM       │
│  ├── Poll until all ECS services RUNNING (~30s)             │
│  └── Invoke Producer Lambda async (kick-off tick loop)      │
└────────────────────────────┬────────────────────────────────┘
                             │ async invoke
                             ▼
┌─────────────────────────────────────────────────────────────┐
│  TICK LOOP (60 self-invocations × ~1s interval)             │
│                                                             │
│  Producer Lambda (timeout: 10s)                             │
│  ├── Read run_state from DynamoDB (abort if STOPPED/FAILED) │
│  ├── Read last prices (PRICE_STATE in DynamoDB)             │
│  ├── Apply GBM → generate 5 tick records                    │
│  ├── Publish to Kafka topic: raw-ticks                      │
│  ├── Save prices + increment tick_count (DynamoDB)          │
│  ├── Sleep ~1s                                              │
│  └── Invoke self async (next tick)                          │
│                          OR (tick 60)                       │
│  └── Invoke Teardown Lambda async                           │
└──────────────┬──────────────────────────────────────────────┘
               │ 5 messages/tick × 60 ticks = 300 messages
               ▼
┌─────────────────────────────────────────────────────────────┐
│  STREAMING LAYER (ECS Fargate, private subnets)             │
│                                                             │
│  Kafka (KRaft, single-node, EFS-backed)                     │
│  Topics: raw-ticks · enriched-ticks · vwap-ticks · alerts   │
│       │                        │                            │
│       ▼                        ▼                            │
│  Flink (JobManager +      Kafka Connect                     │
│         TaskManager)      S3 Sink                           │
│  ├── 10s VWAP windows          │                            │
│  ├── Anomaly detection         ▼                            │
│  │   (price spike >2%,    S3 Processed Zone                 │
│  │    volume spike >3×)                                     │
│  ├── Enriched tick                                          │
│  │   pass-through                                           │
│  └── Alerts → SNS                                           │
└─────────────────────────────────────────────────────────────┘
                             │
                             ▼ (on completion)
┌─────────────────────────────────────────────────────────────┐
│  TEARDOWN + ETL                                             │
│                                                             │
│  Teardown Lambda (timeout: 30s)                             │
│  ├── Set ECS desiredCount = 0 (all 4 services)              │
│  ├── Update DynamoDB run_state = COMPLETED                  │
│  └── Trigger Glue ETL job                                   │
│                │                                            │
│                ▼                                            │
│  Glue PySpark ETL → S3 Curated Zone                         │
│  ├── fact_tick_events      (partitioned by date/symbol)     │
│  ├── fact_vwap             (10s VWAP windows: high, low, total volume)             │
│  ├── dim_symbols           (reference dimension)            │
│  ├── agg_daily_summary     (daily price/volume aggregates)  │
│  └── agg_alerts            (all triggered anomalies)        │
│                │                                            │
│                ▼                                            │
│  Amazon Athena (ad-hoc SQL over Parquet)                    │
└─────────────────────────────────────────────────────────────┘
```

---

## Tech Stack

| Layer | Technology | Notes |
|---|---|---|
| Trigger | REST API (API Gateway) + S3 Dashboard | Event-driven — no scheduled jobs |
| Orchestration | AWS Lambda (Controller, 180s timeout) | Starts ECS, waits for healthy, kicks off loop |
| Tick Loop | AWS Lambda (self-invoking, 60 iterations) | GBM price sim, Kafka publish, DynamoDB state |
| State | Amazon DynamoDB (single-table design) | Run state + per-symbol price persistence |
| Streaming Broker | Apache Kafka 3.7 (KRaft) on ECS Fargate | No ZooKeeper — KRaft mode, EFS for persistence |
| Stream Processing | Apache Flink 1.19 on ECS Fargate | VWAP windows, anomaly detection, enrichment |
| S3 Delivery | Kafka Connect S3 Sink on ECS Fargate | Open-source Firehose alternative — Kafka ecosystem |
| Batch ETL | AWS Glue (PySpark) | Dimensional model: 2 fact, 1 dim, 2 aggregate tables |
| Query | Amazon Athena | Ad-hoc SQL over Parquet in curated zone |
| Alerting | Amazon SNS | Email on price/volume anomaly |
| Infrastructure | Terraform >= 1.5 (16 modules) | Modular, mirrors nasdaq-equity-airflow-ecs-pipeline |
| CI/CD | GitHub Actions + OIDC | No long-lived AWS credentials |
| Dashboard | Vanilla HTML/CSS/JS on S3 | Dark terminal UI, real-time polling |

---

## Key Design Decisions

### Event-Driven, Not Scheduled
The pipeline starts on demand via API call — no EventBridge cron jobs. The Controller Lambda handles idempotency: if a run is already active, a `409 Conflict` is returned. The dashboard gives a visual trigger; `curl` gives a CLI equivalent.

### Lambda Self-Invocation for 1-Second Cadence
EventBridge has a minimum schedule rate of 1 minute. Step Functions adds cost and complexity. Each Producer Lambda invocation sleeps for the remainder of 1 second after publishing, then fires an async self-invocation for the next tick. This produces ~1s cadence for exactly 60 invocations.

### KRaft Mode (No ZooKeeper)
ZooKeeper is deprecated as of Kafka 3.5 and removed in Kafka 4.0. This project uses KRaft from day one — single-node KRaft (broker + controller combined) is appropriate for a portfolio project. Production deployments would use 3+ controller nodes.

### ECS Start-on-Demand, Stop-on-Completion
ECS services run at `desiredCount=0` when idle. The Controller Lambda sets `desiredCount=1`; the Teardown Lambda resets to `0` after 60 ticks. Streaming infrastructure costs nothing when not in use — ~3 min ECS runtime per day vs 60 min in a scheduled design.

### DynamoDB Single-Table Design
Two key patterns stored in one table:
- `pk=CURRENT_RUN, sk=STATE` — run metadata, tick_count, run_state, last_prices snapshot
- `pk=PRICE_STATE, sk=<SYMBOL>` — last GBM price per symbol for continuity across Lambda invocations

### Kafka Connect S3 Sink (Not Kinesis Firehose)
Self-managed Kafka Connect running as an ECS container. Demonstrates Kafka ecosystem knowledge beyond brokers. Open-source, portable, not AWS-locked.

### Simulated Data (GBM, Not Real API)
No external API dependencies or rate limits. Geometric Brownian Motion with per-symbol volatility and drift parameters. Prices persist in DynamoDB between invocations for continuity. Architecture is the focus.

---

## Stock Universe

| Symbol | Base Price | Volatility (σ) | Drift (μ) |
|---|---|---|---|
| AAPL  | $182.00 | 0.25 | 0.08 |
| MSFT  | $415.00 | 0.22 | 0.10 |
| GOOGL | $175.00 | 0.28 | 0.09 |
| AMZN  | $195.00 | 0.30 | 0.12 |
| NVDA  | $875.00 | 0.45 | 0.15 |

Prices evolve using GBM with `dt = 1 / (252 × 6.5 × 3600)` (1 second as a fraction of a trading year).

---

## Project Structure

```
nasdaq-stock-streaming-pipeline/
├── lambda/
│   ├── producer/
│   │   ├── handler.py              # GBM tick sim → Kafka, self-invoking 60×
│   │   └── requirements.txt
│   ├── controller/
│   │   ├── handler.py              # Starts ECS, idempotency, kicks off loop
│   │   └── requirements.txt
│   ├── teardown/
│   │   ├── handler.py              # Stops ECS, triggers Glue ETL
│   │   └── requirements.txt
│   └── status/
│       ├── handler.py              # Dashboard polling endpoint
│       └── requirements.txt
├── flink/
│   └── jobs/
│       └── stock_tick_processor.py  # VWAP, anomaly detection, enrichment
├── glue/
│   └── jobs/
│       └── curated_layer_builder.py # Dimensional model ETL (PySpark)
├── kafka/
│   └── config/
│       ├── kraft-broker.properties   # KRaft single-node config
│       └── s3-sink-connector.properties
├── docker/
│   ├── kafka/                        # Dockerfile + entrypoint.sh
│   ├── kafka-connect/                # Dockerfile + entrypoint.sh
│   ├── flink-jobmanager/             # Dockerfile + entrypoint.sh
│   └── flink-taskmanager/            # Dockerfile
├── dashboard/
│   └── index.html                    # S3-hosted control panel
├── terraform/
│   ├── main.tf                       # Root config — wires 16 modules
│   ├── variables.tf
│   ├── outputs.tf
│   ├── envs/dev/terraform.tfvars
│   └── modules/
│       ├── networking/               # VPC, subnets, SGs, Cloud Map
│       ├── iam/                      # Roles and policies
│       ├── s3/                       # Raw, processed, curated, scripts buckets
│       ├── ecr/                      # 4 container repositories
│       ├── dynamodb/                 # Pipeline state table
│       ├── ecs/                      # ECS cluster
│       ├── efs/                      # Kafka log persistence
│       ├── ecs_kafka/                # Kafka KRaft service
│       ├── ecs_kafka_connect/        # Kafka Connect service
│       ├── ecs_flink/                # Shared module: JM + TM
│       ├── lambda/                   # Shared module: 4 functions
│       ├── glue/                     # Job, database, crawler
│       ├── sns/                      # Alert topic + subscriptions
│       ├── api_gateway/              # REST API, 3 routes, CORS
│       ├── dashboard/                # S3 static website
│       └── github_oidc/              # OIDC provider for CI/CD
├── config/
│   └── dev.yaml                      # Runtime config (GBM params, thresholds)
├── scripts/                          # Helper/utility scripts
├── tests/
│   ├── test_producer.py
│   ├── test_controller.py
│   ├── test_teardown.py
│   └── test_status.py
├── .github/
│   └── workflows/deploy.yml          # CI/CD pipeline
├── conftest.py                       # Pytest shared fixtures
├── startup.md                        # Step-by-step deployment guide
└── README.md
```

---

## ECS Services

All services run on Fargate in private subnets. Service discovery via AWS Cloud Map (internal DNS within VPC).

| Service | CPU | Memory | Image Base | Notes |
|---|---|---|---|---|
| Kafka (KRaft) | 2048 | 4096 MB | apache/kafka:3.7.0 | EFS volume mount for log persistence |
| Kafka Connect | 512 | 1024 MB | confluentinc/cp-kafka-connect:7.6.0 | S3 sink pre-installed |
| Flink JobManager | 1024 | 2048 MB | flink:1.19-scala_2.12 | REST on port 8081 |
| Flink TaskManager | 2048 | 4096 MB | flink:1.19-scala_2.12 | 2 task slots |

All services idle at `desiredCount=0`. Controller Lambda sets to `1`; Teardown Lambda resets to `0`.

---

## Kafka Topics

| Topic | Partitions | Retention | Producer | Consumer |
|---|---|---|---|---|
| `raw-ticks` | 3 | 2h | Producer Lambda | Flink, Kafka Connect |
| `enriched-ticks` | 3 | 2h | Flink | Kafka Connect |
| `vwap-ticks` | 3 | 2h | Flink | Kafka Connect |
| `alerts` | 1 | 24h | Flink | SNS / Kafka Connect |

Topics are pre-created by Terraform (`auto.create.topics.enable=false`).

---

## Glue Output Tables (S3 Curated Zone)

| Table | Type | Partition | Description |
|---|---|---|---|
| `fact_tick_events` | Fact | date, symbol | Individual tick records |
| `fact_vwap` | Fact | date, symbol | 10-second VWAP windows with high, low, total volume |
| `dim_symbols` | Dimension | — | Symbol reference data |
| `agg_daily_summary` | Aggregate | date | Daily price/volume aggregates |
| `agg_alerts` | Aggregate | date | All triggered anomaly alerts |

All tables stored as Parquet in S3, queryable via Athena.

---

## API Reference

| Method | Endpoint | Description |
|---|---|---|
| `POST` | `/pipeline/start` | Start the pipeline (409 if already running) |
| `GET` | `/pipeline/status` | Poll run state, tick count, live prices |
| `DELETE` | `/pipeline/stop` | Manually stop pipeline mid-run |

### Start via CLI
```bash
curl -X POST https://<api-id>.execute-api.ap-southeast-1.amazonaws.com/dev/pipeline/start
```

### Poll Status
```bash
curl https://<api-id>.execute-api.ap-southeast-1.amazonaws.com/dev/pipeline/status
```

### Example Response (RUNNING)
```json
{
  "run_id": "a3f8c21b",
  "run_state": "RUNNING",
  "tick_count": 34,
  "total_ticks": 60,
  "progress_pct": 56.7,
  "elapsed_seconds": 36.2,
  "last_prices": {
    "AAPL": 182.37,
    "MSFT": 415.12,
    "GOOGL": 174.89,
    "AMZN": 196.04,
    "NVDA": 878.22
  }
}
```

---

## CI/CD Pipeline

GitHub Actions with OIDC authentication (no stored AWS credentials):

```
push to main
    │
    ├── Lint & Unit Tests (flake8 + pytest)
    │
    ├── Terraform Plan (OIDC → AWS)
    │
    ├── Build & Push Docker Images (4 services in parallel → ECR)
    │
    ├── Terraform Apply (requires manual approval)
    │
    └── Upload Glue Scripts to S3
```

Pull requests run lint, tests, and `terraform plan` only.

---

## Prerequisites

- AWS account with appropriate permissions
- Terraform >= 1.5
- AWS CLI v2
- Docker (for building container images locally)
- Python 3.11+
- An S3 bucket for Terraform remote state

---

## Quick Start

> For a full step-by-step deployment walkthrough including Docker image builds, GitHub Actions setup, Athena queries, and troubleshooting, see [startup.md](startup.md).

```bash
# 1. Clone
git clone https://github.com/YOUR_GITHUB_USERNAME/nasdaq-stock-streaming-pipeline.git
cd nasdaq-stock-streaming-pipeline

# 2. Configure Terraform variables
cp terraform/envs/dev/terraform.tfvars terraform/envs/dev/terraform.tfvars.local
# Edit terraform.tfvars.local with your values (owner, alert_emails, github_org)

# 3. Deploy infrastructure
cd terraform
terraform init \
  -backend-config="bucket=<your-tf-state-bucket>" \
  -backend-config="region=ap-southeast-1"
terraform apply -var-file=envs/dev/terraform.tfvars

# 4. Build and push Docker images (or let CI/CD handle this)
# See docker/ directory for each service's Dockerfile

# 5. Start the pipeline
curl -X POST $(terraform output -raw api_start_url)

# 6. Watch it run
watch -n 2 "curl -s $(terraform output -raw api_status_url) | python3 -m json.tool"

# 7. Query results in Athena (after Glue ETL completes, ~5 min)
# SELECT * FROM stock_streaming_dev.agg_daily_summary ORDER BY symbol;
```

---

## Running Tests

```bash
pip install -r lambda/producer/requirements.txt
pip install pytest pytest-mock
pytest tests/ -v
```

---

## Monthly Cost Estimate (~$6.45)

All ECS services idle at `desiredCount=0` between runs. Cost only accrues during the ~3-minute window per run (ECS startup + 60-second tick loop + teardown).

| Service | Cost/month |
|---|---|
| Fargate (4 services, ~3 min/day) | $0.83 |
| EFS (Kafka log persistence) | $0.30 |
| Lambda (free tier) | $0.00 |
| DynamoDB (free tier) | $0.00 |
| API Gateway (~30 req/day) | $0.00 |
| Glue ETL (1 job/day, 2 DPU) | $4.40 |
| S3 + Athena + CloudWatch | $0.72 |
| ECR (4 images) | $0.20 |
| **Total** | **~$6.45** |

Based on 1 run/day in `ap-southeast-1`. Significantly cheaper than a scheduled design (~$13.76/month) because ECS runs for ~3 minutes instead of 60.

---

## Related Projects

- [nasdaq-equity-airflow-ecs-pipeline](https://github.com/Ysuperwave135/nasdaq-equity-airflow-ecs-pipeline) — the batch pipeline this project extends with a streaming, event-driven architecture
