"""
test_failure_dag.py — Intentional failure DAG for demo purposes

Used in Scene 3 of the manager demo. Triggers the full AI RCA pipeline.
Realistic error messages simulate actual production failures.

Schedule: None (manual trigger only)
"""
import random
from datetime import datetime, timedelta

from airflow import DAG
from airflow.exceptions import AirflowException
from airflow.operators.python import PythonOperator

from utils.rca_callback import generate_rca_on_failure

# Realistic production error scenarios for demo
DEMO_FAILURE_SCENARIOS = [
    {
        "error": "FileNotFoundError: /data/sales/2024-01-15.csv: No such file or directory",
        "description": "Missing input data file — common ETL failure",
    },
    {
        "error": (
            "ConnectionError: Could not connect to Hive metastore at hive.data-platform.svc:9083\n"
            "Caused by: java.net.ConnectException: Connection refused\n"
            "  at org.apache.thrift.transport.TSocket.open(TSocket.java:183)"
        ),
        "description": "Hive metastore connection failure",
    },
    {
        "error": (
            "py4j.protocol.Py4JJavaError: An error occurred while calling o142.showString.\n"
            "Caused by: java.lang.OutOfMemoryError: Java heap space\n"
            "  at org.apache.spark.storage.DiskBlockObjectWriter.write(DiskBlockObjectWriter.scala:251)\n"
            "  at org.apache.spark.shuffle.sort.BypassMergeSortShuffleWriter.write(BypassMergeSortShuffleWriter.scala:156)"
        ),
        "description": "Spark executor OOM — resource exhaustion",
    },
    {
        "error": (
            "OperationalError: FATAL: remaining connection slots are reserved for non-replication superuser connections\n"
            "psycopg2.OperationalError: could not connect to server: Connection refused\n"
            "  Is the server running on host 'postgres.data-platform.svc' and accepting TCP/IP connections on port 5432?"
        ),
        "description": "PostgreSQL connection pool exhausted",
    },
    {
        "error": (
            "AirflowException: Task exited with return code 1\n"
            "PermissionError: [Errno 13] Permission denied: '/data/output/report_2024_01_15.parquet'\n"
            "  The service account 'airflow-worker' lacks write permission on GCS bucket gs://prod-data-lake/output/"
        ),
        "description": "GCS permission denied — IAM misconfiguration",
    },
]


default_args = {
    "owner": "data-engineering",
    "retries": 0,   # No retries — we want the failure to trigger RCA immediately
    "email_on_failure": False,
    "email_on_retry": False,
    "on_failure_callback": generate_rca_on_failure,
}


def _pre_failure_task(**context):
    """Simulates normal upstream task succeeding."""
    import time
    print("✅ Pre-failure task: Loading configuration...")
    time.sleep(2)
    print("✅ Pre-failure task: Validating schema...")
    time.sleep(1)
    print("✅ Pre-failure task: Establishing connections...")
    time.sleep(1)
    print("✅ Pre-failure task: Completed successfully.")
    return {"status": "success", "records_expected": 1_250_000}


def _intentional_failure(**context):
    """
    Intentionally raises a realistic production error.
    Triggers on_failure_callback → Ollama RCA → email/Slack.

    This is the primary demo task for manager presentation.
    """
    import time

    # Pick a realistic error scenario (or use DEMO_SCENARIO env var for deterministic demo)
    import os
    scenario_idx = int(os.getenv("DEMO_FAILURE_SCENARIO", str(random.randint(0, len(DEMO_FAILURE_SCENARIOS) - 1))))
    scenario = DEMO_FAILURE_SCENARIOS[scenario_idx % len(DEMO_FAILURE_SCENARIOS)]

    print(f"Running ETL task... scenario: {scenario['description']}")
    time.sleep(3)   # Simulate some work before failure
    print("Processing batch 1 of 3... ✅")
    time.sleep(2)
    print("Processing batch 2 of 3... ✅")
    time.sleep(2)
    print(f"Processing batch 3 of 3... ❌ {scenario['description']}")

    # Raise the realistic error — this triggers on_failure_callback
    raise AirflowException(scenario["error"])


def _post_failure_task(**context):
    """This task never runs — here to show the DAG structure."""
    print("This task would run after successful ETL completion.")
    print("Since the previous task failed, this never executes.")


with DAG(
    dag_id="test_failure_dag",
    description="Demo DAG: intentional failure triggers AI RCA pipeline",
    default_args=default_args,
    schedule_interval=None,   # Manual trigger only
    start_date=datetime(2024, 1, 1),
    catchup=False,
    tags=["poc", "demo", "rca", "failure-simulation"],
    doc_md="""
## Test Failure DAG — Manager Demo

This DAG intentionally fails to demonstrate the AI-powered RCA pipeline.

### How to use:
1. Trigger this DAG manually from the Airflow UI
2. Watch the `intentional_failure` task fail with a realistic error
3. Within 30-60 seconds, receive an email with AI-generated RCA
4. The email contains:
   - Root cause identified by Ollama (gemma2:2b)
   - Confidence score
   - Immediate fix steps
   - Prevention recommendations
   - Severity assessment

### Demo scenarios (set DEMO_FAILURE_SCENARIO env var 0-4):
- 0: Missing input file (FileNotFoundError)
- 1: Hive metastore connection failure
- 2: Spark executor OOM (OutOfMemoryError)
- 3: PostgreSQL connection pool exhausted
- 4: GCS permission denied

### Business case:
- Without AI: On-call engineer gets raw stack trace at 3am
- With AI: Diagnosis + fix steps delivered in <60 seconds automatically
""",
) as dag:

    pre_task = PythonOperator(
        task_id="pre_failure_task",
        python_callable=_pre_failure_task,
    )

    failure_task = PythonOperator(
        task_id="intentional_failure",
        python_callable=_intentional_failure,
    )

    post_task = PythonOperator(
        task_id="post_failure_task",
        python_callable=_post_failure_task,
        trigger_rule="all_success",   # Never runs when failure_task fails
    )

    pre_task >> failure_task >> post_task
