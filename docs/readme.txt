Personal GCP (you control everything)
    → Prove Ollama + Airflow RCA works end-to-end
    → Prove anomaly detection works
    → Document the exact images, configs, YAML files used
    → Capture metrics (response time, accuracy, cost = $0 internal)
         ↓
Present to manager with working demo
         ↓
Manager raises with Platform Admin:
    → Namespace request
    → Harbor push approval
    → Network policy approval
    → GPU quota (or confirm CPU-only is acceptable)
         ↓
GDC deployment using exact same YAML, just different registry URL