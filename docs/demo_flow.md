Yes, exactly! Here's the full demo flow:

Demo Flow (10 min recording)
Scene 1 — Show the platform is running (2 min)

kubectl get pods --all-namespaces
Show Airflow UI: kubectl port-forward svc/airflow-webserver 8080:8080 -n airflow
Open browser → http://localhost:8080
Show all 4 DAGs are there and healthy
Scene 2 — Trigger the failure (1 min)

bash demo/inject-failure.sh
In Airflow UI, watch test_failure_dag run
Watch the task turn red (failed)
Say: "Without AI, this is all an on-call engineer gets at 3am — a red task and raw logs"
Scene 3 — AI RCA arrives (2 min)
Within 30-60 seconds of failure → check email subhashbohra003@gmail.com
Email arrives with:
Root cause — exactly what went wrong
Confidence score — e.g. 87%
Immediate fix — exact command to run
Prevention — how to stop it happening again
Severity badge — HIGH / CRITICAL
Estimated fix time — e.g. 15 minutes
What the email looks like

Subject: [HIGH] DAG Failure: test_failure_dag | RCA Generated

Root Cause: Input file not found in GCS bucket — 
            upstream ingestion job failed to deliver data

Immediate Fix: 
  gsutil ls gs://pipeline-data/raw/sales/2024-01-15.csv
  Re-trigger ingestion DAG or restore from backup

Confidence: 87%
Severity: HIGH
Fix time: 15 minutes
Prevention: Add file sensor before processing task
Scene 4 — Show it's all local (30 sec)

kubectl get pods -n llm-serving
Show Ollama running inside the cluster
Say: "No data left the cluster — Ollama ran entirely inside GKE, zero external API calls"
Scene 5 — Business case (1 min)
Open README.md — shows ROI table
Before AI: Engineer wakes up at 3am, spends 90 min diagnosing
After AI: RCA delivered in 30 seconds, fix in 15 min
Saves 780 hours/year across a team
This is a very compelling demo. Keep watching Phase 1 — share the screenshot when it completes!


image.png
1273×691
here
Phase 1 is complete! All 4 nodes are Ready. Phase 2 (Spark Operator) is now installing.

The warning duplicate port definition is harmless — Helm will still install correctly.

Keep watching — share the next screenshot when you see either:

✅ Spark Operator installed successfully! — Phase 2 done
PHASE 3 — Ollama starting
Any error in red
Phase 2 should complete in ~3-5 minutes.

