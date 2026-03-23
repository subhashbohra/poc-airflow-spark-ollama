# Manager Demo Script
## Airflow + Spark + Ollama AI-Powered Pipeline PoC
**Duration:** ~10 minutes | **Audience:** Engineering Manager / Leadership

---

## Pre-Demo Checklist (5 min before)

Run these commands and have them ready in separate terminal tabs:

```bash
# Tab 1 — Airflow UI
kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow

# Tab 2 — Grafana
kubectl port-forward svc/kube-prometheus-stack-grafana 3000:80 -n monitoring

# Tab 3 — Live pod watch
watch kubectl get pods --all-namespaces

# Tab 4 — Demo commands
cd poc-airflow-spark-ollama
```

Verify everything green:
```bash
bash demo/run-demo.sh
```

**Have Gmail open** to show the incoming RCA email in real time.

---

## Scene 1 — Show the Existing Platform (2 min)

**What you say:**
> "This is our production-grade Airflow deployment running on GKE — same architecture as our enterprise GDC cluster. Same Helm chart, same KubernetesExecutor, same namespace isolation."

**What you show:**
1. Open Airflow UI → `http://localhost:8080`
   - Show 4 DAGs: `rca_dag`, `wordcount_dag`, `anomaly_detection_dag`, `test_failure_dag`
   - Point out tags: `spark`, `rca`, `ollama`

2. Switch to Tab 3 (pod watch) → say:
   > "Every namespace is isolated. Airflow workers, Spark jobs, and the LLM all run in separate namespaces with network policies between them."

3. Run:
   ```bash
   kubectl get pods --all-namespaces
   ```
   Point out:
   - `airflow` namespace: webserver, scheduler
   - `llm-serving` namespace: ollama pod
   - `spark-operator` namespace: operator controller

**Key message:** "This mirrors our GDC architecture exactly. We're not building something new — we're adding AI to what we already know works."

---

## Scene 2 — The Old Way: Traditional Failure (2 min)

**What you say:**
> "Let me show you what our on-call engineers deal with today at 3am when a pipeline fails."

**What you do:**
1. In Airflow UI → `test_failure_dag` → click **Trigger DAG**
2. Wait ~12 seconds for failure (you can see it turn red in the grid)
3. Click on the failed task → **Log** tab

**Show the raw error:**
```
[2024-01-15 03:14:23] py4j.protocol.Py4JJavaError: An error occurred...
Caused by: java.lang.OutOfMemoryError: Java heap space
  at org.apache.spark.storage.DiskBlockObjectWriter.write(DiskBlockObjectWriter.scala:251)
  ... 47 more
```

**What you say:**
> "This is all an on-call engineer gets. A Java stack trace at 3am. They need to:
> - Figure out what caused the OOM
> - Find the right Spark config to change
> - Estimate how long the fix will take
> - Decide whether to page the data team
>
> Average diagnosis time: **90 minutes**."

---

## Scene 3 — The New Way: AI-Powered Failure (3 min)

**What you say:**
> "Now watch what happens with AI-enhanced observability."

**What you do:**
```bash
# Trigger with the OOM scenario
bash demo/inject-failure.sh 2
```

**Narrate while waiting (30-45 seconds):**
> "The moment the task fails, our on_failure_callback fires automatically. It:
> 1. Collects the error context and last 100 log lines
> 2. Queries historical run data from PostgreSQL
> 3. Sends everything to our internal Ollama LLM — completely air-gapped, no external APIs
> 4. Gets back a structured JSON diagnosis in about 30 seconds"

**When the email arrives — show it:**
- Red severity badge: **HIGH**
- Root cause: *"Spark executor Java heap space exhausted due to insufficient memory allocation for the shuffle operation on a large dataset"*
- Confidence score: **85%**
- Immediate fix (in a green box): *"Increase executor memory: set spark.executor.memory=2g and spark.sql.shuffle.partitions=200 in SparkApplication YAML"*
- Prevention: *"Add memory-based autoscaling and data volume monitoring to trigger pre-emptive scaling"*
- Estimated fix time: **15 minutes**

**What you say:**
> "The on-call engineer gets this within 60 seconds of the failure. No more stack trace archaeology.
>
> From 90 minutes to 15 minutes — and the engineer didn't have to be an expert in Spark internals."

---

## Scene 4 — Anomaly Detection (2 min)

**What you say:**
> "We're not just reactive — we're also proactive."

**What you do:**
1. Show `anomaly_detection_dag` running on its 30-minute schedule
2. Open Grafana → `http://localhost:3000` → "Pipeline Health" dashboard
3. Point to "DAG Run Duration Over Time" panel

**What you say:**
> "Every 30 minutes, this DAG checks if any pipeline's execution time has drifted more than 2 standard deviations from its baseline.
>
> When it detects drift, Ollama explains what typically causes that pattern — resource contention, data volume spikes, external dependency slowness."

**Show the anomaly detection logic:**
```sql
-- This view calculates it automatically
SELECT dag_id, avg_duration, upper_threshold
FROM dag_baselines;
```

**What you say:**
> "This is the difference between knowing your pipeline failed and knowing your pipeline is *about to* fail."

---

## Scene 5 — The Business Case (1 min)

Open `README.md` and show the ROI table.

**Speak to the numbers:**

| Metric | Before | After |
|--------|--------|-------|
| Diagnosis time | 90 min | 15 min |
| On-call confidence | Low | High |
| Engineer required | Senior Spark expert | Any engineer |
| Time to escalate | 30+ min | Immediate (AI assesses severity) |

> "780 hours per year saved across the team. At fully-loaded engineer cost, that's roughly $150K in reclaimed engineering time — on $60 of GCP spend for this proof of concept."

**Key message:**
> "This PoC proves the pattern works. The next step is deploying the same architecture on GDC using our existing Airflow Helm chart. The DAGs, the Ollama integration, the RCA callback — they all transfer directly."

---

## Common Questions

**Q: Is this calling OpenAI or any external API?**
> No. Ollama runs entirely inside the cluster as a ClusterIP service. Network policies block all external LLM traffic. The gemma2:2b model (Google's open-source model) runs on CPU — no GPU required.

**Q: How accurate is the RCA?**
> In testing, confidence averages 75-85% for common failure patterns. It's not replacing engineers — it's giving them a 15-minute head start instead of a 90-minute archaeology session.

**Q: What's the production path?**
> The same Helm chart we used here is what's deployed on GDC. We'd:
> 1. Move model storage to GCS-backed PVC
> 2. Add Workload Identity for GCP service auth
> 3. Wire into existing PagerDuty for escalation
> 4. Tune the prompt templates on real historical failures

**Q: What does this cost in production?**
> CPU inference with gemma2:2b adds ~30-45 seconds per failure event. For our scale (~20-30 failures/week), that's negligible. The model fits in 3.5GB RAM — no GPU surcharge.

---

## Teardown After Demo

```bash
bash teardown.sh
```

This cleanly removes all GCP resources. Nothing left running to accrue cost.
