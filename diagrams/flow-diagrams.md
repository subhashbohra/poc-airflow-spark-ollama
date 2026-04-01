# Flow Diagrams — Airflow + Spark + Ollama RCA PoC

Four Mermaid diagrams covering every major data and control flow in the PoC.
Render these in any Mermaid-compatible viewer (GitHub, VS Code with Mermaid extension, mermaid.live).

---

## Diagram 1: Model Acquisition Flow

How the gemma2:2b model gets from HuggingFace into the cluster and becomes a live API endpoint.

```mermaid
flowchart LR
  HF["🤗 HuggingFace Registry\ngemma2:2b model\n(hosted externally)"]
  OD["Ollama Pod\nllm-serving namespace\nollama/ollama:latest"]
  PVC["30GB PersistentVolume\n/root/.ollama/models\ngemma2:2b — 1.6 GB on disk"]
  SERVE["Model Serving Engine\nAPI: 0.0.0.0:11434\nTemp: 0.1 · Max tokens: 512"]
  SVC["ollama-service (ClusterIP)\nport 11434\nNetworkPolicy: airflow ns only"]
  NP["NetworkPolicy\nIngress: from namespace=airflow\nEgress: blocked externally"]

  HF -->|"ollama pull gemma2:2b\none-time setup only"| OD
  OD -->|"Persisted to PVC\nsurvives pod restarts"| PVC
  PVC -->|"Loaded into memory\non pod start"| SERVE
  SERVE -->|"Bound to ClusterIP\nport 11434"| SVC
  SVC -->|"Protected by"| NP

  style HF fill:#FF6B35,color:#fff
  style OD fill:#7C3AED,color:#fff
  style PVC fill:#8B5CF6,color:#fff
  style SERVE fill:#7C3AED,color:#fff
  style SVC fill:#6D28D9,color:#fff
  style NP fill:#EF4444,color:#fff
```

---

## Diagram 2: DAG Failure → RCA Complete Flow

Full sequence from task failure to RCA email landing in inbox — target: 30–60 seconds total.

```mermaid
sequenceDiagram
  participant S as Airflow Scheduler
  participant W as Worker Pod<br/>(ephemeral, K8sExecutor)
  participant CB as rca_callback.py<br/>(utils/rca_callback.py)
  participant DB as PostgreSQL<br/>(dag_metrics table)
  participant O as Ollama :11434<br/>(gemma2:2b)
  participant E as Email + Slack<br/>(notifier.py)

  S->>W: Create pod for task (KubernetesExecutor)
  activate W
  W->>W: Task executes normally

  Note over W: Task raises exception:<br/>FileNotFoundError / ConnError /<br/>OOMError / AirflowException

  W--xW: TASK FAILED
  deactivate W

  W->>CB: on_failure_callback(context)
  activate CB

  CB->>CB: Extract: dag_id, task_id, run_id
  CB->>CB: Extract: exception type + message (500 chars)
  CB->>CB: Extract: last 100 log lines (2000 chars)
  CB->>CB: Calculate: task duration_seconds

  CB->>DB: SELECT avg_duration, stddev, recent_statuses<br/>WHERE dag_id = %s AND state = 'success'
  activate DB
  DB-->>CB: Historical context: total_runs, avg_duration,<br/>last 3 statuses, baseline thresholds
  deactivate DB

  CB->>CB: Build structured prompt<br/>(rca_prompt.py RCA_PROMPT_TEMPLATE)

  CB->>O: POST /api/generate<br/>{ model: gemma2:2b, format: json,<br/>  stream: false, temperature: 0.1 }
  activate O
  Note over O: Analyzes:<br/>- Error type + message<br/>- Log patterns<br/>- Historical context<br/>- Duration anomaly

  O-->>CB: { root_cause, root_cause_category,<br/>  confidence, immediate_fix,<br/>  prevention, severity,<br/>  retry_recommended,<br/>  estimated_fix_time_minutes }
  deactivate O

  CB->>CB: Validate JSON response<br/>Fallback if parse fails

  CB->>DB: INSERT INTO dag_metrics (<br/>  rca_root_cause, rca_category,<br/>  rca_confidence, rca_severity,<br/>  rca_immediate_fix, rca_prevention,<br/>  rca_model_used, rca_response_time_seconds<br/>)
  activate DB
  DB-->>CB: Row inserted (id)
  deactivate DB

  CB->>E: send_failure_email(dag_id, rca)
  CB->>E: send_slack_alert(dag_id, rca)
  activate E
  Note over E: Email: Rich HTML template<br/>Severity badge, confidence score,<br/>fix steps, Airflow UI link<br/><br/>Slack: Block Kit message<br/>Root cause bold, immediate fix,<br/>action button
  E-->>CB: Notifications sent
  deactivate E

  deactivate CB

  Note over S,E: Total elapsed: 30–60 seconds<br/>from task failure to inbox
```

---

## Diagram 3: Ephemeral Spark Job Flow

How Airflow triggers a Spark job and how the SparkApplication lifecycle ensures full cleanup.

```mermaid
flowchart TD
  DAG["Airflow DAG\nwordcount_dag.py / rca_dag.py\nSparkKubernetesOperator"]
  APPLY["kubectl apply -f\nSparkApplication CR\nname: wordcount-[run_id]\nnamespace: spark-jobs"]
  CR["SparkApplication CR\napiVersion: sparkoperator.k8s.io/v1beta2\nrestartPolicy: Never"]
  OP["Spark Operator Controller\nnamespace: spark-operator\nWatches spark-jobs namespace"]
  SA["ServiceAccount: spark\nClusterRole: SparkApplication R/W\nRBAC in spark-jobs ns"]
  DP["Driver Pod\nspark-jobs namespace\n1 core · 512m memory\napache/spark:3.5.0"]
  EP["Executor Pods (×2)\nspark-jobs namespace\n1 core · 512m each\nauto-scaled if needed"]
  WORK["WordCount Job Running\nProcesses input text\nCounts word frequencies\nWrites output"]
  JC{Job Complete?}
  DONE["SparkApplication: Completed\nDriver Pod: Terminated\nExecutor Pods: Deleted\nCR: Deleted by DAG cleanup task"]
  FAIL["SparkApplication: FAILED\nLogs collected by operator\non_failure_callback fires\nOllama RCA triggered"]
  VERIFY["DAG: verify_completion task\nChecks SparkApplication .status.applicationState\nExpects: COMPLETED"]
  CLEANUP["DAG: cleanup task\nkubectl delete sparkapplication\nwordcount-[run_id] -n spark-jobs"]

  DAG -->|"SparkKubernetesOperator\napplies manifest"| APPLY
  APPLY --> CR
  CR -->|"CR detected"| OP
  OP -->|"Uses RBAC"| SA
  SA -->|"Creates"| DP
  DP -->|"Requests executors"| EP
  EP -->|"Execute job"| WORK
  WORK --> JC

  JC -->|"SUCCESS"| DONE
  JC -->|"FAILED / Timeout"| FAIL

  DONE --> VERIFY
  VERIFY -->|"Status: COMPLETED"| CLEANUP

  FAIL -->|"on_failure_callback"| RCA["rca_callback.py\nOllama analysis\nEmail + Slack alert"]

  style DONE fill:#10B981,color:#fff
  style FAIL fill:#EF4444,color:#fff
  style RCA fill:#7C3AED,color:#fff
  style DAG fill:#0EA5E9,color:#fff
  style OP fill:#F59E0B,color:#fff
  style DP fill:#FEF3C7
  style EP fill:#FEF3C7
  style CLEANUP fill:#10B981,color:#fff
```

---

## Diagram 4: Observability and Anomaly Detection Flow

How raw run data becomes actionable alerts through baseline computation and drift detection.

```mermaid
flowchart LR
  subgraph SOURCES["Data Sources"]
    AF["Airflow DAGs\nrun duration, state\nexecution_date\ntask-level metrics"]
    RCA_SRC["RCA Results (Ollama)\nroot_cause_category\nconfidence score\nresponse_time_seconds"]
    K8S["Kubernetes\npod cpu/memory\nrestart counts\nnode utilization"]
  end

  subgraph STORAGE["Storage Layer"]
    PG[("PostgreSQL\ndag_metrics table\n+ dag_baselines VIEW\nmonitor namespace")]
    PROM["Prometheus\ntime-series TSDB\nkube-prometheus-stack\nscrape: 15s interval"]
  end

  subgraph ANOMALY["Anomaly Detection (every 30 min)"]
    FETCH["fetch_recent_metrics\nSELECT last 10 runs\nper dag_id WHERE\nstate = 'success'"]
    COMPUTE["compute_baselines\navg_duration per DAG\n± 2 × stddev threshold\nrequires >= 5 runs"]
    DETECT["detect_anomalies\nFlag: duration > upper\nor duration < lower\nor consecutive failures"]
    EXPLAIN["explain_anomaly\nOllama: ask why this\nDAG ran slow/fast\nJSON explanation"]
  end

  subgraph ALERTS["Alerting"]
    EMAIL_A["Email Alert\nAnomaly detected\nAI explanation\nBaseline comparison"]
    SLACK_A["Slack Alert\nDrift percentage\nExpected vs actual\nFix recommendation"]
  end

  subgraph PRESENT["Presentation Layer"]
    GF["Grafana Dashboard\npipeline-health.json\nkubectl port-forward 3000"]
    PANELS["Dashboard Panels\n· DAG success rate (7d)\n· RCA categories pie chart\n· Duration vs baseline line\n· Ollama response times\n· Anomaly event markers\n· Top failure tasks table"]
  end

  AF -->|"duration_seconds\nstate, error_message"| PG
  RCA_SRC -->|"rca_* columns\nINSERT on failure"| PG
  K8S -->|"pod metrics\nnode metrics"| PROM

  PG --> FETCH
  FETCH --> COMPUTE
  COMPUTE --> DETECT
  DETECT -->|"anomaly_score > 0"| EXPLAIN
  EXPLAIN -->|"AI explanation\n+ severity"| EMAIL_A
  EXPLAIN -->|"AI explanation\n+ severity"| SLACK_A

  DETECT -->|"no anomaly"| NO_ALERT["No alert\nMetrics logged only"]

  PG -->|"dag_metrics data\nvia Grafana datasource"| GF
  PROM -->|"cluster metrics\nvia Grafana datasource"| GF
  GF --> PANELS

  style PG fill:#10B981,color:#fff
  style PROM fill:#10B981,color:#fff
  style GF fill:#059669,color:#fff
  style EMAIL_A fill:#6B7280,color:#fff
  style SLACK_A fill:#6B7280,color:#fff
  style EXPLAIN fill:#7C3AED,color:#fff
  style NO_ALERT fill:#D1D5DB,color:#374151
```

---

## Quick Reference — Namespace and Port Map

| Namespace | Component | Internal Port | Access |
|---|---|---|---|
| `airflow` | Webserver | 8080 | `kubectl port-forward svc/airflow-webserver 8080:8080` |
| `airflow` | Scheduler | — | Internal only |
| `llm-serving` | Ollama | 11434 | ClusterIP only (from airflow ns) |
| `spark-operator` | Controller | 8080 (webhook) | Internal only |
| `spark-jobs` | Driver/Executors | ephemeral | Deleted post-completion |
| `monitoring` | PostgreSQL | 5432 | Internal only |
| `monitoring` | Prometheus | 9090 | `kubectl port-forward svc/prometheus 9090:9090` |
| `monitoring` | Grafana | 3000 | `kubectl port-forward svc/grafana 3000:3000` |

---

## RCA Data Flow Summary

```
Task FAILS
    │
    ▼  on_failure_callback (synchronous, same worker pod)
    │
    ├─► Collect context (logs, error, duration, run history)
    │
    ├─► Build prompt (rca_prompt.py RCA_PROMPT_TEMPLATE)
    │       Includes: dag_id, task_id, error_type, error_message,
    │                 log_excerpt (2000 chars), historical stats
    │
    ├─► POST ollama-service.llm-serving.svc.cluster.local:11434/api/generate
    │       model: gemma2:2b
    │       format: json (forces structured output)
    │       temperature: 0.1 (deterministic)
    │       timeout: 120s
    │
    ├─► Parse JSON response → validate all required keys
    │
    ├─► INSERT INTO dag_metrics (all rca_* columns)
    │
    ├─► send_failure_email → smtp.gmail.com:587 (HTML template)
    │
    └─► send_slack_alert  → Incoming Webhook (Block Kit)

Total wall-clock time: 30–60 seconds
```

---

*Generated for poc-airflow-spark-ollama — GKE + Airflow + Spark + Ollama RCA PoC*
*Architecture mirrors enterprise GDC deployment pattern*
