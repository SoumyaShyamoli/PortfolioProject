# Runbook — starting, stopping, and reaching the Airflow instances

Related: ADR 0014.

---

## Start an instance

```bash
cd infra/terraform
```

Edit `terraform.auto.tfvars` (or pass `-var`):

```hcl
airflow_instance_state = "running"
```

```bash
terraform plan -out=tfplan     # expect 1-2 changes (the null_resource toggle)
terraform apply tfplan
```

Takes 1-2 minutes for EC2 to report `running`, then another 30-60 seconds
for the `airflow-scheduler` and `airflow-webserver` systemd services to come
up (they start automatically on boot — no manual step).

Verify:

```bash
aws ec2 describe-instances \
  --instance-ids $(terraform output -json airflow_instance_ids | jq -r '.dev') \
  --query "Reservations[].Instances[].State.Name" --output text --profile retail-dev
```

## Stop an instance

Same as above with `airflow_instance_state = "stopped"`. Whatever DAG run
was in progress does not gracefully finish — stopping mid-run leaves that
run in whatever state Airflow's SQLite database recorded at the moment of
stop. Check no DAG is actively running before stopping.

## Reaching the webserver UI

No public IP, no inbound security group rule — reached through SSM Session
Manager port forwarding, not a browser hitting the instance directly.

```bash
aws ssm start-session \
  --target <instance-id> \
  --document-name AWS-StartPortForwardingSession \
  --parameters '{"portNumber":["8080"],"localPortNumber":["8080"]}' \
  --profile retail-dev
```

Then browse to `http://localhost:8080`. Close the session (Ctrl+C) when
done — it does not time out on its own.

## Deploying a DAG change

CI (`airflow-deploy.yml`) does this automatically on merge to `main` for
changes under `airflow/dags/`. To do it by hand:

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["aws s3 cp s3://<staged-bucket>/_airflow-dags/retail_pipeline.py /opt/airflow/dags/retail_pipeline.py","chown airflow:airflow /opt/airflow/dags/retail_pipeline.py"]' \
  --profile retail-dev
```

Airflow's scheduler picks up a changed DAG file within its normal DAG
refresh interval (default 30s) — no service restart needed for a DAG
change, only for a change to `airflow.cfg` or the executor configuration.

## Triggering a DAG run

DAGs are unscheduled — every run needs a `{"year": ..., "month": ...}`
config, since the source data is historical and there is no "current
month" to default to.

Via the UI: Trigger DAG w/ Config, paste the JSON.

Via CLI, over the same SSM session:

```bash
aws ssm send-command \
  --instance-ids <instance-id> \
  --document-name "AWS-RunShellScript" \
  --parameters 'commands=["sudo -u airflow AIRFLOW_HOME=/opt/airflow /opt/airflow/venv/bin/airflow dags trigger retail_pipeline_dev --conf {\"year\":2010,\"month\":12}"]' \
  --profile retail-dev
```

## What "pause" actually means here

Stopping the instance stops EC2 compute billing. It does **not** stop the
attached EBS volume from being billed — a stopped instance still accrues a
small monthly storage charge until it is **terminated**, not merely
stopped.

**Never run `terraform destroy` on the Airflow resources** to "clean up" —
`lifecycle { prevent_destroy = true }` will refuse this, and the guard has
to be deliberately removed first. If genuinely done with the project and
the ongoing EBS charge is unwanted, terminate deliberately:

```bash
terraform state rm 'aws_instance.airflow["dev"]'
aws ec2 terminate-instances --instance-ids <instance-id> --profile retail-dev
```

Removing from state first means Terraform will not try to manage a
resource that no longer exists on the next plan. This is a one-way door —
the DAG files and Airflow metadata on that instance are gone. Re-provisioning
means a fresh `terraform apply` and a full re-bootstrap.

## Cost while stopped

Roughly £0.30-0.40/month per stopped instance (20GB gp3 EBS), until
terminated. Two stopped instances left indefinitely: under £1/month —
cheap, but not literally zero, and it is easy to forget about.
