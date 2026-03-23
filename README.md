# Airflow + Spark + Ollama — AI-Powered Data Pipeline PoC

An enterprise-grade data pipeline proof of concept demonstrating AI-powered root cause analysis, anomaly detection, and automated incident response — deployed on GKE using the same Helm patterns as our production GDC environment.

---

## Architecture

```
GKE Cluster (us-central1-a) — poc-cluster
│
├── namespace: airflow
│   ├── Airflow Webserver (e2-standard-4 spot)
│   ├── Airflow Scheduler
│   ├── Airflow Workers (KubernetesExecutor — ephemeral pods per task)
│   └── PostgreSQL (Airflow metadata DB — Helm subchart)
│
├── namespace: spark-operator
│   └── Spark Operator Controller
│
├── namespace: spark-jobs
│   └── Ephemeral SparkApplication pods
│       (auto-created on DAG trigger, deleted on completion)
│
├── namespace: llm-serving
│   ├── Ollama Deployment (gemma2:2b, CPU-only)  ← ClusterIP only
│   ├── ClusterIP Service :11434
│   └── PVC 30GB (model storage, persists across restarts)
│
├── namespace: monitoring
│   ├── PostgreSQL (dag_metrics table — RCA history)
│   ├── Prometheus
│   └── Grafana (Pipeline Health dashboard)
│
└── Network Policies
    └── Only airflow → llm-serving traffic on :11434 allowed
        All other LLM ingress blocked
```

---

## What Was Built

### 4 AI-Enhanced Capabilities

| Capability | Before | After |
|---|---|---|
| **Failure diagnosis** | Raw stack trace | AI root cause + fix steps in 60s |
| **Confidence score** | None | 75-90% AI confidence rating |
| **On-call guidance** | Senior expert required | Any engineer can act on AI report |
| **Anomaly detection** | Manual threshold alerts | Automatic 2σ baseline with AI explanation |

### 5 Core Components

1. **`rca_dag.py`** — Spark WordCount + AI RCA on any failure
2. **`test_failure_dag.py`** — Intentional failure for demo (5 realistic error scenarios)
3. **`anomaly_detection_dag.py`** — 30-min baseline check + Ollama drift explanation
4. **`wordcount_dag.py`** — Pure Spark integration test (ephemeral job pattern)
5. **Ollama (gemma2:2b)** — Internal LLM, ClusterIP only, no external API calls

---

## Business Case

### Before AI (Current State)
- On-call engineer receives: raw Java/Python stack trace
- Time to identify root cause: **90 minutes** (average)
- Requires: senior engineer familiar with Spark internals
- Escalation decision: manual, delayed

### After AI (This PoC)
- On-call engineer receives: structured RCA email within 60 seconds
  - Root cause sentence
  - Confidence score (%)
  - Exact fix command/steps
  - Severity badge (low/medium/high/critical)
  - Estimated resolution time
- Time to identify root cause: **15 minutes**
- Requires: any engineer
- Escalation decision: AI-assisted (severity + escalate_to_oncall flag)

### ROI Summary

| Metric | Value |
|---|---|
| Diagnosis time reduction | 90 min → 15 min (83% faster) |
| Hours saved per incident | 1.25 hours |
| Incidents per year (estimate) | 624 (12/week) |
| **Total hours saved per year** | **780 hours** |
| Engineer cost (fully loaded) | ~$200/hr |
| **Annual value** | **~$156,000** |
| GCP PoC cost (full day) | ~$5.30 |
| GCP PoC total (1 week) | ~$37 |

---

## Quick Start

### Prerequisites
- `gcloud` CLI authenticated to project `ollama-491104`
- `kubectl` installed
- `helm` v3.x installed
- Gmail App Password (for email notifications)

### One-Shot Setup

```bash
cd poc-airflow-spark-ollama

# With email notifications
PROJECT_ID=ollama-491104 \
EMAIL=subhashbohra003@gmail.com \
SMTP_PASSWORD=your_gmail_app_password \
bash setup.sh

# Optional: add Slack
SLACK_WEBHOOK_URL=https://hooks.slack.com/services/xxx \
bash setup.sh
```

Setup takes approximately **25-35 minutes** (model download is the longest step).

### Access the Services

```bash
# Airflow UI (admin/admin)
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow
# → http://localhost:8080

# Grafana (admin/poc-grafana-admin)
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring
# → http://localhost:3000
```

### Run the Demo

```bash
# 1. Verify everything is working
bash demo/run-demo.sh

# 2. Trigger intentional failure (Spark OOM scenario)
bash demo/inject-failure.sh 2

# 3. Watch email arrive within 60 seconds at subhashbohra003@gmail.com
```

See [demo/DEMO-SCRIPT.md](demo/DEMO-SCRIPT.md) for the full manager presentation guide.

### Teardown

```bash
bash teardown.sh
```

---

## GCP Cost Breakdown

| Resource | Machine Type | Mode | Est. $/hr |
|---|---|---|---|
| System node pool | e2-standard-2 | On-demand | ~$0.07 |
| Airflow node pool | e2-standard-4 | Spot | ~$0.05 |
| Spark node pool | e2-standard-4 | Spot (0-3 nodes) | ~$0.05-0.10 |
| Ollama node pool | e2-standard-4 | Spot | ~$0.05 |
| **Total** | | | **~$0.22/hr** |

Full day running ≈ **$5.30**. Full week ≈ **$37**.
Well within the $300 GCP credit budget.

---

## Key Technical Decisions

| Decision | Choice | Rationale |
|---|---|---|
| Executor | KubernetesExecutor | Matches GDC enterprise pattern |
| LLM | gemma2:2b via Ollama | CPU-only, no GPU cost, Google's model |
| LLM exposure | ClusterIP only | Mirrors GDC air-gap, no external traffic |
| Spark jobs | restartPolicy: Never | Ephemeral pattern, matches GDC |
| Node pools | Spot instances | Cost optimization for PoC |
| Schema | PostgreSQL dag_metrics | Baseline data for anomaly detection |

---

## Next Steps for Enterprise GDC Deployment

1. Replace PVC model storage with GCS-backed persistent volume
2. Add Workload Identity for GCP service account authentication
3. Wire severity=high/critical into PagerDuty escalation
4. Fine-tune RCA prompts on 90 days of real historical failures
5. Add Spark metrics to Grafana dashboard (Spark History Server)
6. Enable remote logging to GCS for Airflow task logs

---

*PoC built on personal GCP | Project: ollama-491104 | Architecture mirrors enterprise GDC*
*Model: gemma2:2b (Google open-source) | No external API calls | All inference on-cluster*
