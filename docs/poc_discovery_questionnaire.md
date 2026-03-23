# Discovery Questionnaire — AI-Enhanced Data Pipeline Platform
## Pre-PoC Stakeholder Interview Guide

**Purpose:** Understand current pain points, operational maturity, and org-wide scope before presenting the PoC.
**Audience:** Your manager, platform leads, and any pipeline/data engineering stakeholders.
**How to use:** Go through these in a 45–60 min conversation. You don't need all answers — even partial responses will shape your PoC scope and pitch significantly.

---

## SECTION 1 — Current Scale and Landscape

> Goal: Understand the true size of what you're dealing with before proposing org-wide solutions.

1. How many Airflow environments (clusters/projects) are currently running across the organization? Are they all on GKE/GDC or are some managed elsewhere (Cloud Composer, on-prem, etc.)?

2. Approximately how many DAGs are in active use today across all projects? How many are considered business-critical (i.e., SLA-bound or feeding production systems)?

3. How many distinct teams or business units own and operate their own pipelines? Do they manage their own Airflow instances or share a central one?

4. Is there a central platform team responsible for the Airflow infrastructure, or is it fully decentralized — each team managing their own?

5. Are all pipelines on the same GCP organization/billing account, or are they spread across multiple projects, billing accounts, or even different clouds?

6. What is the rough ratio of data engineers to DAGs? (e.g., 1 engineer maintains how many DAGs on average?)

7. Are there any pipelines outside Airflow — for example, Cloud Workflows, Dataflow, dbt, or custom cron jobs — that are not currently covered by any orchestration observability?

---

## SECTION 2 — Current Incident Response and RCA Process

> Goal: Find out exactly how failures are handled today — this is where the pain is most visible and the ROI is easiest to quantify.

8. When a DAG fails today, what is the exact notification mechanism? (Email alert? PagerDuty? Slack? Manual check of the Airflow UI?)

9. Who receives failure notifications — the owning team only, or is there a central on-call rotation that covers all pipelines?

10. When an engineer gets a failure alert, what do they do first? Walk me through the typical investigation steps from alert to resolution.

11. On average, how long does it take from the time a DAG fails to the time the root cause is identified? And how long from root cause identified to resolution?

12. Is there any documented RCA process today? Do engineers log findings somewhere (Confluence, JIRA, incident tickets) or is it tribal knowledge that lives in Slack threads?

13. How often does the same failure pattern repeat across DAGs or teams? Is there any mechanism to learn from past incidents and prevent recurrence?

14. What percentage of failures are resolved by the owning engineer vs escalated to a senior engineer or platform team? What are the most common escalation reasons?

15. Are there any known "mystery failures" — DAGs that fail intermittently with no clear cause and no consistent fix?

16. Has the organization ever experienced a cascading failure where one DAG's failure triggered downstream failures across multiple pipelines or teams? What was the impact?

---

## SECTION 3 — Monitoring, Observability, and Alerting

> Goal: Understand what visibility exists today and where the blind spots are.

17. Is there any centralized monitoring dashboard for pipeline health across all teams and clusters? If yes, what tool (Grafana, Cloud Monitoring, Datadog, custom)? If no, how does leadership currently know if pipelines are healthy?

18. Are DAG execution times currently tracked and baselined anywhere? Does anyone know what "normal" looks like for any given pipeline?

19. Are there SLA definitions for any pipelines today? If yes, how are SLA breaches detected and who is accountable?

20. What logs are currently collected from Airflow DAGs and where are they stored? (Cloud Logging, Stackdriver, local, nowhere?)

21. Are Spark job logs (from Spark Operator) correlated with their triggering Airflow DAGs anywhere? Or are they siloed in separate systems?

22. Is there any alerting today for anomalies — for example, a DAG that used to run in 10 minutes but now takes 45? Or data volume drops that might indicate upstream feed issues?

23. Are there any existing tools or scripts built internally to help with monitoring or alerting, even if informal? (Slack bots, Python scripts, cron jobs that check Airflow APIs, etc.)

24. How much alert fatigue exists today? Do engineers ignore alerts because there are too many, or are alerts generally meaningful and actionable?

---

## SECTION 4 — Multi-Team and Multi-Cluster Governance

> Goal: This is the critical section for your "100 teams, 10,000 DAGs" concern. Understand the political and technical landscape before proposing cross-cutting solutions.

25. Is there a governance or standards body (e.g., data platform guild, architecture review board) that sets rules for how pipelines are built across teams? Or does each team build in their own way?

26. Are there common DAG coding standards or templates used across the organization, or does every team have its own conventions?

27. If a centralized observability or AI layer were introduced, who would own it? Would it sit with a central platform team, or would each team need to adopt it independently?

28. What are the data privacy and security constraints across teams? Are some pipelines handling PII or regulated data (GDPR, HIPAA, SOC2) where log data from those DAGs cannot be centrally collected without specific controls?

29. If a cross-team monitoring solution were introduced, would teams need to opt in individually, or could it be mandated centrally? What is the governance model for cross-team tooling?

30. Are there organizational boundaries (e.g., separate business units with separate IT budgets) that would make a single unified solution difficult? Would a federated model (each team's data stays in their project, but a central view aggregates summaries) be more acceptable?

31. Are there existing integration points — shared GCP organization, shared VPC, shared Cloud Logging sink — that could be used to aggregate pipeline telemetry without requiring each team to change their DAGs?

32. Has any previous attempt at org-wide pipeline standardization or centralized monitoring been made? If yes, what happened — did it succeed, fail, or stall? Why?

---

## SECTION 5 — Pipeline Development and Velocity

> Goal: Understand the current developer experience so UC-4 (NL DAG Generator) and efficiency gains can be quantified accurately.

33. How long does it take a new data engineer to go from joining the team to being able to write and deploy a production DAG independently? What is the biggest learning curve?

34. Are there common DAG templates or cookiecutter projects that engineers start from, or does everyone build from scratch each time?

35. What is the most common type of DAG being built across teams? (e.g., Hive/Spark ETL, API ingestion, Trino query, ML feature pipeline)

36. How much time do engineers typically spend on boilerplate DAG configuration (retry logic, failure callbacks, scheduling, dependency management) vs actual business logic?

37. Are there pipelines that multiple teams independently built to do essentially the same thing? Is there duplication of effort that a shared template or generator could eliminate?

38. Is there a formal code review process for new DAGs before they go to production? How long does that cycle take on average?

---

## SECTION 6 — Cost and Resource Visibility

> Goal: Understand whether cost attribution and optimization are already concerns — this strengthens the infrastructure savings part of the business case.

39. Is there any cost attribution today for pipeline-level compute? Do teams know what individual DAGs or Spark jobs cost to run?

40. Are there known expensive or inefficient pipelines that run longer or use more resources than expected? Has anyone been able to quantify the waste?

41. Are GKE clusters right-sized for actual workloads, or is there suspicion of over-provisioning? Has any cost optimization exercise been done recently?

42. When a Spark job uses significantly more resources than expected (memory spikes, longer runtime), is that visible to anyone in real time, or only discovered after the fact in billing?

43. Is there pressure from leadership or finance to optimize cloud spend on data workloads? Has there been any mandate around FinOps or cost visibility for data pipelines?

---

## SECTION 7 — Strategic Alignment and Leadership Appetite

> Goal: Understand the political landscape before you walk into the leadership presentation.

44. Is there existing leadership appetite for AI-powered operations (AIOps)? Has the topic come up in any strategic planning conversations or OKRs?

45. Are there any competing initiatives underway — another team building an observability platform, a vendor evaluation for a commercial tool like DataDog or Monte Carlo — that this PoC might overlap or conflict with?

46. What does success look like to your manager specifically? Is it cost savings, engineering velocity, reduced incidents, or something else? What metric would make them most excited?

47. Has the organization previously tried to adopt AI tooling for operations (e.g., AIOps platforms, ML-based monitoring)? What was the outcome?

48. Who are the key internal champions and skeptics you would anticipate for a proposal like this? What objections are likely to come up?

49. Is there a preference for build vs buy? Would leadership be more receptive to a vendor solution (e.g., Astronomer, Monte Carlo, Bigeye) or an internally built solution on GCP? What factors drive that preference?

50. What is the typical timeline and approval process for moving a PoC to production? Who needs to sign off, and what evidence do they require?

---

## SECTION 8 — Integration and Architecture Constraints

> Goal: Understand the technical constraints that would affect how you integrate the AI layer across 100 teams and 10,000 DAGs.

51. Is there a shared GCP organization with centralized IAM, or are teams in separate GCP organizations? This directly affects whether a single Vertex AI project can serve all teams.

52. Are there network isolation requirements (VPC Service Controls, private clusters) that would prevent DAG logs from being sent to a central Cloud Logging project?

53. What is the current Airflow version deployed across clusters? Are all clusters on the same version, or is there version drift? (This matters for which callback APIs and provider packages are available.)

54. Is there a standard CI/CD pipeline for deploying DAGs (GitHub Actions, Cloud Build, Jenkins)? Could an AI validation step be inserted into that pipeline?

55. Are there any restrictions on what external APIs DAGs can call during execution? (Some organizations restrict outbound calls from DAG tasks for security reasons — this would affect the Gemini RCA callback.)

56. For the self-healing agent use case: is the Airflow REST API currently enabled and accessible in all clusters? Are there any security policies that restrict programmatic modification of DAGs or task states?

57. For the anomaly detection use case: is BigQuery already used by any teams for operational data? Is there an existing project where pipeline metrics could be written without creating new billing or access concerns?

---

## SECTION 9 — Quick Win Identification

> Goal: Find the one or two most painful problems that would make the strongest immediate case for the PoC.

58. If you could fix just ONE thing about how pipelines are operated today, what would it be?

59. Which team or pipeline has caused the most operational pain in the last 6 months? What happened?

60. Is there a specific upcoming event or deadline (a major data migration, a product launch, an audit) where improved pipeline reliability would have an immediate and visible impact?

61. Which engineers spend the most time firefighting pipeline failures instead of building new things? Can you quantify how many hours per week that is?

62. If a Gemini RCA tool had existed during the worst pipeline incident in the last year, approximately how much time would it have saved?

---

## SECTION 10 — Ideal End State (Vision Alignment)

> Goal: Understand where your manager and leadership want to be in 12–24 months, so the PoC can be framed as a first step toward that vision.

63. What does the ideal state of data pipeline operations look like to you in 2 years? What does "fully healthy" mean?

64. Is the goal eventually to have a unified observability platform that all 100 teams use, or is a federated model (each team sees their own, with a central rollup view) more realistic politically?

65. Is there interest in going beyond monitoring — toward autonomous operations where pipelines self-heal without human intervention for a defined class of failures?

66. How important is the "show your work" aspect — i.e., having an audit trail of every AI-generated recommendation and autonomous action for compliance or governance purposes?

67. If this PoC succeeds, what would the 12-month roadmap look like? Who would own the production platform, and what headcount or budget would be allocated?

---

## How to Use These Questions Strategically

**Before the meeting:**
Group the questions into 3–4 themes and pick 15–20 for a 60-minute conversation. Don't read them verbatim — use them as a guide and let the conversation flow naturally.

**Highest-priority questions (if time is short):**
Questions **10, 11, 12, 16, 25, 27, 29, 44, 46, 58, 59, 62** — these will give you the clearest picture of pain, politics, and priority in the shortest time.

**After the meeting:**
Map the answers to your four PoC use cases:
- Many "manual RCA" answers → UC-1 is your headline
- "No baseline" answers → UC-2 is most compelling
- "Repeated failures, no fix" answers → UC-3 is the money slide
- "Slow pipeline creation" answers → UC-4 is your velocity story

**For the multi-team / 100-teams question specifically:**
Questions 25–32 and 51–57 are your architecture discovery questions. The answers will tell you whether to propose:
- A **centralized model** (one shared AI layer, all teams push metrics to it)
- A **federated model** (each team deploys their own AI callbacks, summaries roll up centrally)
- A **hybrid model** (shared observability infra, siloed execution data with privacy controls)

---

_Questionnaire prepared by: Data Engineering Team | March 2026_
_Version 1.0 — Pre-PoC Discovery Phase_
