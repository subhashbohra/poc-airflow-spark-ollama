"""
rca_dag.py — Main PoC DAG: Spark WordCount + AI-powered RCA on failure

Flow:
  check_ollama_health → run_spark_wordcount → record_metrics
  [any failure] → on_failure_callback → Ollama RCA → email/Slack

Schedule: @daily
This DAG is the primary showcase of AI-enhanced pipeline observability.
"""
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.sensors.python import PythonSensor
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator

from utils.rca_callback import generate_rca_on_failure
from utils.anomaly_detector import store_metric
from utils.ollama_client import check_ollama_health

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=5),
    "email_on_failure": False,   # We handle email in on_failure_callback
    "email_on_retry": False,
    "on_failure_callback": generate_rca_on_failure,
}

SPARK_APP_TEMPLATE = """
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: wordcount-{{ run_id | replace(":", "-") | replace("+", "-") | lower | truncate(50, True, '') }}
  namespace: spark-jobs
spec:
  type: Scala
  mode: cluster
  image: "apache/spark:3.5.0"
  imagePullPolicy: Always
  mainClass: org.apache.spark.examples.JavaWordCount
  mainApplicationFile: "local:///opt/spark/examples/jars/spark-examples_2.12-3.5.0.jar"
  arguments:
    - "local:///opt/spark/examples/jars/spark-examples_2.12-3.5.0.jar"
  sparkVersion: "3.5.0"
  restartPolicy:
    type: Never
  driver:
    cores: 1
    coreLimit: "1200m"
    memory: "512m"
    serviceAccount: spark
    labels:
      version: "3.5.0"
    tolerations:
      - key: "pool"
        operator: "Equal"
        value: "spark"
        effect: "NoSchedule"
    nodeSelector:
      pool: spark
  executor:
    cores: 1
    instances: 2
    memory: "512m"
    labels:
      version: "3.5.0"
    tolerations:
      - key: "pool"
        operator: "Equal"
        value: "spark"
        effect: "NoSchedule"
    nodeSelector:
      pool: spark
"""


def _check_ollama_health_fn(**context):
    """Verify Ollama is reachable before running the pipeline."""
    is_healthy = check_ollama_health()
    if not is_healthy:
        raise Exception(
            "Ollama health check failed. "
            "Verify: kubectl get pods -n llm-serving && "
            "kubectl get svc -n llm-serving"
        )
    return True


def _record_metrics(**context):
    """Record successful run metrics to PostgreSQL dag_metrics table."""
    dag_id = context["dag"].dag_id
    run_id = context["run_id"]
    execution_date = context["execution_date"]
    task_instance = context["task_instance"]

    # Calculate duration from DAG start to now
    dag_run = context.get("dag_run")
    start_date = dag_run.start_date if dag_run else datetime.utcnow()
    end_date = datetime.utcnow()
    duration = (end_date - start_date).total_seconds() if start_date else 0

    store_metric(
        dag_id=dag_id,
        task_id="record_metrics",
        run_id=run_id,
        execution_date=execution_date if isinstance(execution_date, datetime) else datetime.utcnow(),
        start_date=start_date,
        end_date=end_date,
        duration_seconds=duration,
        state="success",
    )
    return {"duration_seconds": duration, "state": "success"}


with DAG(
    dag_id="rca_dag",
    description="Main PoC: Spark WordCount + Ollama RCA on failure",
    default_args=default_args,
    schedule_interval="@daily",
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["poc", "spark", "rca", "ollama"],
    doc_md="""
## RCA DAG — AI-Powered Pipeline with Root Cause Analysis

This DAG demonstrates AI-enhanced data pipeline observability:

1. **check_ollama_health** — Verifies the Ollama LLM service is reachable
2. **run_spark_wordcount** — Submits an ephemeral Spark WordCount job via SparkKubernetesOperator
3. **record_metrics** — Logs execution time and status to PostgreSQL for anomaly detection

**On any failure:** `on_failure_callback` automatically:
- Collects error context and log excerpt
- Calls Ollama (gemma2:2b) to generate root cause analysis
- Stores RCA in dag_metrics PostgreSQL table
- Sends rich HTML email + Slack notification with AI diagnosis

**Model:** gemma2:2b (CPU-only, no GPU required)
**LLM Endpoint:** http://ollama-service.llm-serving.svc.cluster.local:11434 (internal ClusterIP only)
""",
) as dag:

    check_ollama = PythonSensor(
        task_id="check_ollama_health",
        python_callable=_check_ollama_health_fn,
        mode="poke",
        poke_interval=30,
        timeout=300,
        soft_fail=False,
    )

    run_spark_wordcount = SparkKubernetesOperator(
        task_id="run_spark_wordcount",
        namespace="spark-jobs",
        application_file=SPARK_APP_TEMPLATE,
        kubernetes_conn_id="kubernetes_default",
        do_xcom_push=True,
        delete_on_termination=True,
    )

    record_metrics = PythonOperator(
        task_id="record_metrics",
        python_callable=_record_metrics,
    )

    check_ollama >> run_spark_wordcount >> record_metrics
