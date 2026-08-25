# ADR 0009 — Alerting on pipeline failures

- **Status:** Accepted
- **Date:** 2026-08-24

## Context

Until now, a failed pipeline run sat in CloudWatch logs until someone
looked. Nothing pushed. For a platform that claims production discipline,
that is a gap.

Three things can fail:

1. The Glue conversion job crashes or times out.
2. The World Bank Lambda fails.
3. The reconciliation does not balance.

The third is the interesting one. Per ADR 0007, the Glue job normally fails
itself on a recon mismatch. But there is an escape hatch —
`--fail_on_recon_mismatch false` — for pushing a known-bad month through
deliberately. Used that way, the job succeeds and the mismatch is invisible.

## Decision

SNS topic per environment, email subscription, three CloudWatch alarms each.

| Alarm | Source | Fires on |
|---|---|---|
| `glue-json-to-parquet-failed` | `Glue` namespace, `numFailedTasks` | job crash or timeout |
| `worldbank-ingest-failed` | `AWS/Lambda` `Errors` | any unhandled exception |
| `recon-mismatch` | log metric filter | `RECON_UNBALANCED` in job output |

The Glue job prints a bare `RECON_UNBALANCED` token when `balanced` is false,
separate from the `RECON_RESULT` JSON line:

```python
print("RECON_RESULT " + json.dumps(recon))
if not balanced:
    print("RECON_UNBALANCED")
```

The metric filter matches that single token.

## Rationale

**The recon alarm is independent of job failure.** It reads the log, not the
job state. So the escape hatch stays usable without creating a silent hole —
the job can succeed and the alarm still fires.

**A dedicated token beats pattern-matching the JSON.** This started as a
workaround: CloudWatch filter patterns choke on quoted strings containing
colons, and `"balanced": false` would not validate. But the result is better
than what I originally wrote. The alert condition is now stated explicitly in
the code instead of inferred from how `json.dumps` happens to format output.
Switch to compact JSON later and the alarm still works.

**Separate topics per environment.** A dev failure while iterating should not
compete for attention with a prod failure. Cheap to do, and it means dev
alerts can be muted without muting prod.

**Email, not Slack.** No Slack workspace for this project. Adding one to
route alerts would be infrastructure existing for the sake of a demo.

## Consequences

**Five-minute evaluation period.** Alarms are not instant. Fine for a batch
pipeline that runs monthly; wrong for anything latency-sensitive.

**Email subscriptions need manual confirmation.** Terraform creates the
subscription but cannot click the link. Until confirmed, alarms fire into
nothing. Worth checking after any apply that recreates the subscription.

**No escalation.** One email, one recipient, no paging, no on-call rotation.
Adequate for a solo project. A real platform would route through PagerDuty or
similar with severity tiers.

**Tested by deliberately failing a job.** Ran the Glue job against
`--year 1999`, which has no raw partitions, and confirmed the email arrived.
An alerting system nobody has seen fire is a claim rather than a control.

Note this only exercised the job-failure alarm. The recon alarm's path was
verified by inspection, not by corrupting an input file.

## What is deliberately not alerted on

Worth naming, because absence of an alarm is a decision too.

- **Freshness / SLA breach.** No alarm for "the pipeline should have run by
  now and did not". Needs an expected-schedule definition, which does not
  exist yet — the job is still triggered manually.
- **Volume anomaly.** A month arriving with 200 rows instead of 40,000 would
  reconcile perfectly and alert nothing. Recon proves nothing was lost in
  transit, not that the right data arrived.
- **Cost.** Covered by the AWS Budget alert set up at the start. A second,
  differently-configured cost alarm would produce confusing
  double-notifications.
- **Snowflake and dbt.** Not built yet.

## Follow-ups

- Add a Firehose delivery-failure alarm when the streaming path is built.
  Same topic, same pattern — the fan-out is designed to take more sources.
- Add freshness alarms once Airflow provides an expected schedule.
- Consider a volume-anomaly check in dbt (row count per month against a
  rolling average) rather than in CloudWatch, since it is a data question
  rather than an infrastructure one.
