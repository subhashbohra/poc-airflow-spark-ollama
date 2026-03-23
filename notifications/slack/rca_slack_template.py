"""
notifications/slack/rca_slack_template.py — Slack Block Kit message builder.
"""


def build_failure_blocks(dag_id, task_id, execution_date, exception, rca: dict) -> list:
    severity = rca.get("severity", "medium").upper()
    emoji = {"LOW": "🟡", "MEDIUM": "🟠", "HIGH": "🔴", "CRITICAL": "🚨"}.get(severity, "⚠️")
    confidence = float(rca.get("confidence", 0))

    return [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"{emoji} DAG Failure — RCA Generated"},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*DAG:*\n`{dag_id}`"},
                {"type": "mrkdwn", "text": f"*Task:*\n`{task_id}`"},
                {"type": "mrkdwn", "text": f"*Time:*\n{str(execution_date)[:19]}"},
                {"type": "mrkdwn", "text": f"*Severity:*\n{severity}"},
            ],
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*🔍 Root Cause:*\n{rca.get('root_cause', 'Unknown')}",
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*🔧 Immediate Fix:*\n```{rca.get('immediate_fix', 'N/A')}```",
            },
        },
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*🛡️ Prevention:*\n{rca.get('prevention', 'N/A')}",
            },
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": (
                        f"Confidence: *{confidence:.0%}* | "
                        f"Fix time: *{rca.get('estimated_fix_time_minutes', '?')} min* | "
                        f"Model: {rca.get('_model_used', 'gemma2:2b')} | "
                        f"Response: {rca.get('_response_time_seconds', '?')}s"
                    ),
                }
            ],
        },
    ]


def build_anomaly_blocks(dag_id, anomaly: dict, explanation: dict) -> list:
    severity = explanation.get("severity", "medium").upper()
    emoji = {"LOW": "🟡", "MEDIUM": "🟠", "HIGH": "🔴"}.get(severity, "⚠️")

    return [
        {
            "type": "header",
            "text": {"type": "plain_text", "text": f"{emoji} Pipeline Anomaly — {dag_id}"},
        },
        {
            "type": "section",
            "fields": [
                {"type": "mrkdwn", "text": f"*DAG:*\n`{dag_id}`"},
                {"type": "mrkdwn", "text": f"*Deviation:*\n+{anomaly.get('deviation_pct', 0):.0f}% above baseline"},
                {"type": "mrkdwn", "text": f"*Current:*\n{anomaly.get('current_duration', 0):.1f}s"},
                {"type": "mrkdwn", "text": f"*Baseline avg:*\n{anomaly.get('avg_duration', 0):.1f}s"},
            ],
        },
        {"type": "divider"},
        {
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*AI Explanation:*\n{explanation.get('anomaly_explanation', 'N/A')}",
            },
        },
        {
            "type": "context",
            "elements": [
                {
                    "type": "mrkdwn",
                    "text": (
                        f"Category: {explanation.get('anomaly_category', 'N/A')} | "
                        f"Severity: {severity} | "
                        f"Auto-recoverable: {explanation.get('auto_recoverable', False)}"
                    ),
                }
            ],
        },
    ]
