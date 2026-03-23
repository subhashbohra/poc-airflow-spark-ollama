"""
notifier.py — Email + Slack notification helpers for RCA and anomaly alerts

Sends rich HTML email and Slack Block Kit messages with AI-generated RCA.
All sending is done via Airflow's built-in SMTP and Slack providers.
"""
import logging
import os
from datetime import datetime
from typing import Optional

log = logging.getLogger(__name__)

AIRFLOW_UI_URL = os.getenv("AIRFLOW_UI_URL", "http://localhost:8080")
FROM_EMAIL = os.getenv("SMTP_MAIL_FROM", "subhashbohra003@gmail.com")
ALERT_EMAIL = os.getenv("ALERT_EMAIL", "subhashbohra003@gmail.com")


def send_failure_email(
    dag_id: str,
    task_id: str,
    execution_date,
    exception,
    rca: dict,
    to: Optional[str] = None,
) -> bool:
    """
    Send rich HTML email with AI-generated RCA report.
    Uses Airflow's send_email utility (SMTP connection).
    """
    try:
        from airflow.utils.email import send_email

        to_address = to or ALERT_EMAIL
        subject = (
            f"[{rca.get('severity', 'UNKNOWN').upper()}] DAG Failure: {dag_id} | "
            f"Task: {task_id} | RCA Generated"
        )

        # Load HTML template
        html_content = _build_failure_email_html(dag_id, task_id, execution_date, exception, rca)

        send_email(
            to=to_address,
            subject=subject,
            html_content=html_content,
        )
        log.info(f"Failure email sent to {to_address} for {dag_id}/{task_id}")
        return True

    except Exception as e:
        log.error(f"Failed to send failure email: {e}")
        return False


def send_anomaly_email(
    dag_id: str,
    anomaly: dict,
    explanation: str,
    ai_analysis: dict,
    to: Optional[str] = None,
) -> bool:
    """Send anomaly detection alert email."""
    try:
        from airflow.utils.email import send_email

        to_address = to or ALERT_EMAIL
        severity = ai_analysis.get("severity", "medium").upper()
        subject = f"[ANOMALY/{severity}] DAG {dag_id} execution time spike detected"
        html_content = _build_anomaly_email_html(dag_id, anomaly, explanation, ai_analysis)

        send_email(to=to_address, subject=subject, html_content=html_content)
        log.info(f"Anomaly email sent to {to_address} for {dag_id}")
        return True
    except Exception as e:
        log.error(f"Failed to send anomaly email: {e}")
        return False


def send_slack_alert(
    dag_id: str,
    task_id: str,
    execution_date,
    exception,
    rca: dict,
) -> bool:
    """
    Send Slack notification with Block Kit formatting.
    Requires slack_default connection configured in Airflow.
    """
    try:
        from airflow.providers.slack.hooks.slack_webhook import SlackWebhookHook

        severity = rca.get("severity", "unknown").upper()
        confidence = int(rca.get("confidence", 0) * 100)

        severity_emoji = {
            "CRITICAL": ":red_circle:",
            "HIGH": ":large_orange_circle:",
            "MEDIUM": ":large_yellow_circle:",
            "LOW": ":large_green_circle:",
        }.get(severity, ":white_circle:")

        blocks = [
            {
                "type": "header",
                "text": {
                    "type": "plain_text",
                    "text": f"{severity_emoji} DAG Failure — AI RCA Generated",
                },
            },
            {
                "type": "section",
                "fields": [
                    {"type": "mrkdwn", "text": f"*DAG:*\n{dag_id}"},
                    {"type": "mrkdwn", "text": f"*Task:*\n{task_id}"},
                    {"type": "mrkdwn", "text": f"*Severity:*\n{severity}"},
                    {"type": "mrkdwn", "text": f"*Confidence:*\n{confidence}%"},
                ],
            },
            {"type": "divider"},
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*Root Cause:*\n{rca.get('root_cause', 'Unknown')}",
                },
            },
            {
                "type": "section",
                "text": {
                    "type": "mrkdwn",
                    "text": f"*Immediate Fix:*\n```{rca.get('immediate_fix', 'See email for details')}```",
                },
            },
            {
                "type": "context",
                "elements": [
                    {
                        "type": "mrkdwn",
                        "text": (
                            f"Category: `{rca.get('root_cause_category', 'unknown')}` | "
                            f"Est. fix: {rca.get('estimated_fix_time_minutes', '?')}min | "
                            f"Retry: {'Yes' if rca.get('retry_recommended') else 'No'} | "
                            f"Model: {rca.get('_model_used', 'ollama')} | "
                            f"Response: {rca.get('_response_time_seconds', '?')}s"
                        ),
                    }
                ],
            },
            {
                "type": "actions",
                "elements": [
                    {
                        "type": "button",
                        "text": {"type": "plain_text", "text": "View in Airflow UI"},
                        "url": f"{AIRFLOW_UI_URL}/dags/{dag_id}/grid",
                        "style": "primary",
                    }
                ],
            },
        ]

        hook = SlackWebhookHook(slack_webhook_conn_id="slack_default")
        hook.send(blocks=blocks)
        log.info(f"Slack alert sent for {dag_id}/{task_id}")
        return True

    except Exception as e:
        log.warning(f"Slack notification failed (may not be configured): {e}")
        return False


def _build_failure_email_html(dag_id, task_id, execution_date, exception, rca) -> str:
    """Build rich HTML email body for DAG failure RCA."""
    severity = rca.get("severity", "unknown").upper()
    confidence = int(rca.get("confidence", 0) * 100)
    category = rca.get("root_cause_category", "unknown").replace("_", " ").title()

    severity_color = {
        "CRITICAL": "#d32f2f",
        "HIGH": "#e65100",
        "MEDIUM": "#f57c00",
        "LOW": "#388e3c",
    }.get(severity, "#616161")

    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    model_used = rca.get("_model_used", "gemma2:2b")
    response_time = rca.get("_response_time_seconds", "?")

    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, sans-serif; margin: 0; padding: 0; background: #f5f5f5; }}
    .container {{ max-width: 680px; margin: 20px auto; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }}
    .header {{ background: {severity_color}; color: #fff; padding: 24px 32px; }}
    .header h1 {{ margin: 0; font-size: 22px; }}
    .header p {{ margin: 6px 0 0; opacity: 0.85; font-size: 14px; }}
    .body {{ padding: 24px 32px; }}
    .meta-grid {{ display: grid; grid-template-columns: 1fr 1fr; gap: 12px; margin: 16px 0; }}
    .meta-item {{ background: #f8f9fa; border-radius: 6px; padding: 12px; }}
    .meta-item .label {{ font-size: 11px; color: #666; text-transform: uppercase; letter-spacing: 0.5px; }}
    .meta-item .value {{ font-size: 14px; font-weight: 600; color: #212121; margin-top: 4px; }}
    .section {{ margin: 20px 0; }}
    .section h2 {{ font-size: 14px; text-transform: uppercase; letter-spacing: 0.5px; color: #666; border-bottom: 1px solid #eee; padding-bottom: 8px; margin-bottom: 12px; }}
    .root-cause {{ background: #fff3e0; border-left: 4px solid {severity_color}; padding: 14px 16px; border-radius: 0 6px 6px 0; font-size: 15px; color: #212121; }}
    .fix-box {{ background: #e8f5e9; border-left: 4px solid #43a047; padding: 14px 16px; border-radius: 0 6px 6px 0; font-family: monospace; font-size: 13px; }}
    .prevention {{ background: #e3f2fd; border-left: 4px solid #1976d2; padding: 14px 16px; border-radius: 0 6px 6px 0; font-size: 14px; }}
    .badge {{ display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; font-weight: 600; background: {severity_color}; color: #fff; }}
    .confidence {{ display: inline-block; padding: 3px 10px; border-radius: 12px; font-size: 12px; background: #e0e0e0; color: #333; }}
    .btn {{ display: inline-block; padding: 12px 24px; background: #1976d2; color: #fff; text-decoration: none; border-radius: 6px; font-weight: 600; margin-top: 16px; }}
    .footer {{ background: #f5f5f5; padding: 16px 32px; font-size: 12px; color: #888; border-top: 1px solid #e0e0e0; }}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>⚠️ DAG Failure — AI Root Cause Analysis</h1>
      <p>AI-powered diagnosis generated in {response_time}s using {model_used}</p>
    </div>
    <div class="body">
      <div class="meta-grid">
        <div class="meta-item">
          <div class="label">DAG</div>
          <div class="value">{dag_id}</div>
        </div>
        <div class="meta-item">
          <div class="label">Task</div>
          <div class="value">{task_id}</div>
        </div>
        <div class="meta-item">
          <div class="label">Execution Date</div>
          <div class="value">{execution_date}</div>
        </div>
        <div class="meta-item">
          <div class="label">Category</div>
          <div class="value">{category}</div>
        </div>
      </div>

      <div style="margin: 12px 0;">
        <span class="badge">{severity}</span>
        &nbsp;
        <span class="confidence">AI Confidence: {confidence}%</span>
        &nbsp;
        {'<span style="background:#43a047;color:#fff;padding:3px 10px;border-radius:12px;font-size:12px;font-weight:600;">RETRY RECOMMENDED</span>' if rca.get('retry_recommended') else ''}
      </div>

      <div class="section">
        <h2>Root Cause</h2>
        <div class="root-cause">{rca.get('root_cause', 'Analysis unavailable')}</div>
      </div>

      <div class="section">
        <h2>Immediate Fix</h2>
        <div class="fix-box">{rca.get('immediate_fix', 'See logs for details')}</div>
        <p style="font-size:13px;color:#666;margin:8px 0 0;">
          Estimated resolution time: <strong>{rca.get('estimated_fix_time_minutes', '?')} minutes</strong>
        </p>
      </div>

      <div class="section">
        <h2>Prevention</h2>
        <div class="prevention">{rca.get('prevention', 'N/A')}</div>
      </div>

      <div class="section">
        <h2>Downstream Impact</h2>
        <p>{rca.get('affected_downstream', 'Unknown')}</p>
      </div>

      <div class="section">
        <h2>Error Details</h2>
        <pre style="background:#f5f5f5;padding:12px;border-radius:6px;font-size:12px;overflow-x:auto;white-space:pre-wrap;">{str(exception)[:800]}</pre>
      </div>

      <a href="{AIRFLOW_UI_URL}/dags/{dag_id}/grid" class="btn">View in Airflow UI →</a>
    </div>
    <div class="footer">
      Generated: {now} &nbsp;|&nbsp; Model: {model_used} &nbsp;|&nbsp; Response time: {response_time}s &nbsp;|&nbsp; Airflow + Ollama RCA PoC
    </div>
  </div>
</body>
</html>"""


def _build_anomaly_email_html(dag_id, anomaly, explanation, ai_analysis) -> str:
    """Build HTML email body for anomaly detection alert."""
    severity = ai_analysis.get("severity", "medium").upper()
    now = datetime.utcnow().strftime("%Y-%m-%d %H:%M UTC")
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <style>
    body {{ font-family: -apple-system, BlinkMacSystemFont, sans-serif; background: #f5f5f5; margin: 0; padding: 0; }}
    .container {{ max-width: 680px; margin: 20px auto; background: #fff; border-radius: 8px; overflow: hidden; box-shadow: 0 2px 8px rgba(0,0,0,0.1); }}
    .header {{ background: #e65100; color: #fff; padding: 24px 32px; }}
    .body {{ padding: 24px 32px; }}
    .metric {{ display: inline-block; padding: 12px 20px; background: #fff3e0; border-radius: 8px; margin: 6px 6px 6px 0; text-align: center; }}
    .metric .val {{ font-size: 24px; font-weight: 700; color: #e65100; }}
    .metric .lbl {{ font-size: 12px; color: #666; }}
    .footer {{ background: #f5f5f5; padding: 12px 32px; font-size: 12px; color: #888; border-top: 1px solid #e0e0e0; }}
  </style>
</head>
<body>
  <div class="container">
    <div class="header">
      <h1>📊 Anomaly Detected — DAG Execution Time Spike</h1>
      <p>Execution time exceeded 2σ baseline threshold</p>
    </div>
    <div class="body">
      <h2 style="margin-top:0">{dag_id}</h2>
      <div>
        <div class="metric"><div class="val">{anomaly['current_duration']:.0f}s</div><div class="lbl">Current Run</div></div>
        <div class="metric"><div class="val">{anomaly['avg_duration']:.0f}s</div><div class="lbl">Average</div></div>
        <div class="metric"><div class="val">{anomaly['upper_threshold']:.0f}s</div><div class="lbl">Threshold (2σ)</div></div>
        <div class="metric"><div class="val">+{anomaly['deviation_pct']:.0f}%</div><div class="lbl">Deviation</div></div>
      </div>
      <h3>AI Explanation</h3>
      <p>{explanation}</p>
      <h3>Recommended Action</h3>
      <p style="background:#e8f5e9;padding:12px;border-radius:6px;">{ai_analysis.get('recommended_action', 'Investigate logs')}</p>
      <p><strong>Likely Cause:</strong> {ai_analysis.get('likely_cause', 'unknown').replace('_', ' ').title()}</p>
      <p><strong>Severity:</strong> {severity} &nbsp;|&nbsp; <strong>Escalate to On-call:</strong> {'Yes' if ai_analysis.get('escalate_to_oncall') else 'No'}</p>
      <a href="{AIRFLOW_UI_URL}/dags/{dag_id}/grid" style="display:inline-block;padding:12px 24px;background:#1976d2;color:#fff;text-decoration:none;border-radius:6px;font-weight:600;">View in Airflow →</a>
    </div>
    <div class="footer">Generated: {now} &nbsp;|&nbsp; Airflow + Ollama Anomaly Detection PoC</div>
  </div>
</body>
</html>"""
