"""
wordcount_dag.py — Simple Spark WordCount DAG (no failure injection)

Proves Spark integration works. Shows the ephemeral pod pattern.
Schedule: None (manual trigger)
"""
from datetime import datetime, timedelta

from airflow import DAG
from airflow.operators.python import PythonOperator
from airflow.providers.cncf.kubernetes.operators.spark_kubernetes import SparkKubernetesOperator
from airflow.providers.cncf.kubernetes.sensors.spark_kubernetes import SparkKubernetesSensor

from utils.rca_callback import generate_rca_on_failure

default_args = {
    "owner": "data-engineering",
    "retries": 1,
    "retry_delay": timedelta(minutes=3),
    "email_on_failure": False,
    "on_failure_callback": generate_rca_on_failure,
}

SPARK_APP_YAML = """
apiVersion: sparkoperator.k8s.io/v1beta2
kind: SparkApplication
metadata:
  name: wordcount-{{ run_id | replace(":", "-") | replace("+", "-") | lower | truncate(48, True, '') }}
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


def _verify_completion(**context):
    """Verify the SparkApplication completed successfully."""
    import subprocess
    run_id = context["run_id"]
    safe_run_id = run_id.replace(":", "-").replace("+", "-").lower()[:48]
    app_name = f"wordcount-{safe_run_id}"

    result = subprocess.run(
        ["kubectl", "get", "sparkapplication", app_name, "-n", "spark-jobs",
         "-o", "jsonpath={.status.applicationState.state}"],
        capture_output=True, text=True, timeout=30,
    )
    state = result.stdout.strip()
    print(f"SparkApplication {app_name} final state: {state}")

    if state != "COMPLETED":
        raise Exception(f"SparkApplication did not complete successfully. State: {state}")

    return {"spark_app": app_name, "state": state}


def _cleanup_spark_app(**context):
    """Delete the SparkApplication CR after completion (ephemeral pattern)."""
    import subprocess
    run_id = context["run_id"]
    safe_run_id = run_id.replace(":", "-").replace("+", "-").lower()[:48]
    app_name = f"wordcount-{safe_run_id}"

    result = subprocess.run(
        ["kubectl", "delete", "sparkapplication", app_name, "-n", "spark-jobs",
         "--ignore-not-found"],
        capture_output=True, text=True, timeout=30,
    )
    print(f"Cleanup result: {result.stdout} {result.stderr}")
    print(f"✅ SparkApplication {app_name} deleted. Pods are ephemeral — already terminated.")


with DAG(
    dag_id="wordcount_dag",
    description="Simple Spark WordCount — proves Spark integration works",
    default_args=default_args,
    schedule_interval=None,
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["poc", "spark", "wordcount"],
    doc_md="""
## WordCount DAG

Demonstrates working Spark integration via SparkKubernetesOperator.

**Pattern:**
1. Submit SparkApplication CR to spark-jobs namespace
2. Wait for completion (driver + executor pods run ephemerally)
3. Verify COMPLETED state
4. Delete SparkApplication CR (pods already terminated)

**Key GDC mirroring:**
- `restartPolicy: Never` — ephemeral jobs, never restart
- KubernetesExecutor — Airflow task pod is also ephemeral
- Spark pods scheduled on dedicated spark-pool (spot instances)
""",
) as dag:

    submit_wordcount = SparkKubernetesOperator(
        task_id="submit_wordcount_job",
        namespace="spark-jobs",
        application_file=SPARK_APP_YAML,
        kubernetes_conn_id="kubernetes_default",
        do_xcom_push=True,
        delete_on_termination=False,   # We handle cleanup explicitly
    )

    verify_completion = PythonOperator(
        task_id="verify_completion",
        python_callable=_verify_completion,
    )

    cleanup = PythonOperator(
        task_id="cleanup_spark_app",
        python_callable=_cleanup_spark_app,
        trigger_rule="all_done",   # Cleanup even if verify fails
    )

    submit_wordcount >> verify_completion >> cleanup
