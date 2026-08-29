# Study Guide — Part 2: Command Reference

Every command run during the build, grouped by purpose, with what each one
does and why it was needed. Placeholders: `PROFILE=retail-dev`,
`ACCOUNT=009073574996`, `REGION=eu-west-2`.

---

## Environment checks

```bash
git --version
aws --version
python3 --version
```

Confirm the toolchain before starting. Cheap, and saves debugging a missing
binary later.

```bash
aws sts get-caller-identity --profile retail-dev
```
Which identity am I actually using? Returns the account ID and the role or
user ARN. The first thing to run when a permissions error looks wrong — it's
often the wrong profile rather than the wrong policy

```bash
aws configure get region --profile retail-dev
```
A "resource not found" that makes no sense is usually a region mismatch.

---

## Git

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
git config --global init.defaultBranch main
```
One-time setup. The third avoids the `master`/`main` mismatch with GitHub.

```bash
git init
git remote add origin https://github.com/OWNER/REPO.git
git branch -M main
git push -u origin main
```
`-M` renames the current branch. `-u` links local `main` to the remote so
later pushes need no arguments.

```bash
git status              # what's changed, staged, and which branch
git log --oneline       # commit history, compact
git ls-files            # what git is TRACKING — not what's on disk
git diff                # unstaged line-by-line changes
git remote -v           # which remote this repo points at
```

`git ls-files` is the important one. `.gitignore` only affects **untracked**
files — anything already committed stays tracked regardless. This is how the
data files got committed before the ignore file existed.

```bash
git rm -r --cached .
git add .
git commit --amend -m "message"
```
Untrack everything (leaving files on disk), re-add respecting `.gitignore`,
and rewrite the last commit. This is how the accidentally-committed data
files were removed before anything was pushed.

```bash
git add -A              # stage everything: new, modified, deleted, whole repo
git rev-parse --show-toplevel    # where IS the repo root?
git check-ignore -v path/to/file # WHICH rule is ignoring this file?
```

`git add .` only covers the current directory downward; `-A` covers the whole
repo. `check-ignore -v` names the offending line when a file mysteriously
doesn't appear in `git status`.

### Safety check before any push

```bash
git ls-files | grep -Ei "tfstate|tfvars|\.env|credentials|\.pem"
```
Must return nothing. State files can contain resource attributes in
plaintext, sometimes including secrets.

---

## S3

```bash
aws s3 mb s3://BUCKET --region eu-west-2 --profile retail-dev
aws s3api list-buckets --query "Buckets[].Name" --output text --profile retail-dev
```

```bash
aws s3 ls s3://BUCKET/prefix/ --recursive --human-readable --profile retail-dev
aws s3 ls s3://BUCKET/prefix --recursive --summarize --human-readable --profile retail-dev
```
`--summarize` appends a total object count and size — this is how the 19.1 MB
raw figure was measured.

```bash
aws s3 cp local/file s3://BUCKET/key --profile retail-dev
aws s3 cp local/dir/ s3://BUCKET/prefix/ --recursive \
  --exclude "*" --include "event_date=2010-12-*" --profile retail-dev
```
`--exclude "*"` then `--include` is the idiom for selective upload. Order
matters: later flags override earlier ones.

```bash
aws s3 cp s3://BUCKET/key - --profile retail-dev
```
`-` as the destination prints to stdout. Useful for reading a small JSON
audit record without downloading it.

```bash
aws s3api get-bucket-lifecycle-configuration --bucket BUCKET --profile retail-dev
aws s3api get-bucket-versioning --bucket BUCKET --profile retail-dev
aws s3api get-bucket-encryption --bucket BUCKET --profile retail-dev
```
Verify what's actually configured, rather than what you believe is. The first
of these proved the lifecycle rule had never saved.

```bash
aws s3api put-object --bucket BUCKET --key prefix/ --profile retail-dev
```
Creates a zero-byte placeholder. Purely cosmetic — S3 has no real folders,
only key prefixes, and any upload creates the apparent structure.

---

## IAM

```bash
aws iam list-roles \
  --query "Roles[?starts_with(RoleName,'retail-')].RoleName" \
  --output text --profile retail-dev

aws iam list-role-policies --role-name ROLE --profile retail-dev
aws iam list-attached-role-policies --role-name ROLE --profile retail-dev

aws iam get-role --role-name ROLE \
  --query 'Role.AssumeRolePolicyDocument' --profile retail-dev

aws iam get-role-policy --role-name ROLE --policy-name POLICY \
  --query 'PolicyDocument' --profile retail-dev
```

Note the distinction, which matters for Terraform import IDs:
- **inline policies** — `list-role-policies`, import ID `role:policy`
- **attached managed policies** — `list-attached-role-policies`, import ID
  `role/policy-arn`

```bash
aws iam create-user --user-name NAME --profile retail-dev
aws iam create-policy --policy-name NAME --policy-document file://policy.json --profile retail-dev
aws iam attach-user-policy --user-name NAME --policy-arn ARN --profile retail-dev
aws iam create-access-key --user-name NAME --profile retail-dev
aws iam list-open-id-connect-providers --profile retail-dev
```

```bash
aws configure --profile retail-dev
export AWS_PROFILE=retail-dev
```
Named profiles keep this project's credentials separate. The export saves
`--profile` on every command; VS Code and boto3 read the same
`~/.aws/credentials` file, so no separate setup is needed for either.

---

## VPC and networking

```bash
VPC=vpc-07ea06521ec2bc50b

aws ec2 describe-vpcs \
  --query "Vpcs[].{Id:VpcId,Cidr:CidrBlock,Default:IsDefault,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table --profile retail-dev

aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" \
  --query "Subnets[].{Id:SubnetId,AZ:AvailabilityZone,Cidr:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
  --output table --profile retail-dev

aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" \
  --query "RouteTables[].{Id:RouteTableId,Main:Associations[0].Main,Subnets:Associations[].SubnetId|join(',',@),Routes:Routes[].DestinationCidrBlock|join(',',@)}" \
  --output table --profile retail-dev

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" \
  --query "SecurityGroups[].{Id:GroupId,Name:GroupName}" \
  --output table --profile retail-dev

aws ec2 describe-security-groups --group-ids sg-XXXX \
  --query "SecurityGroups[].{In:IpPermissions,Out:IpPermissionsEgress}" \
  --profile retail-dev

aws ec2 describe-vpc-endpoints --filters "Name=vpc-id,Values=$VPC" \
  --query "VpcEndpoints[].{Id:VpcEndpointId,Service:ServiceName,Type:VpcEndpointType,RouteTables:RouteTableIds}" \
  --output table --profile retail-dev
```

**Lesson from this set:** always assign the VPC ID to a shell variable first.
Running these with a literal `<vpc-id>` placeholder returns empty results,
which looks identical to the resource not existing — that false negative is
what caused the duplicate-endpoint failure later.

```bash
aws ec2 create-vpc-endpoint --vpc-id $VPC \
  --service-name com.amazonaws.eu-west-2.s3 \
  --vpc-endpoint-type Gateway \
  --route-table-ids rtb-XXXX --profile retail-dev

aws ec2 delete-vpc-endpoints --vpc-endpoint-ids vpce-XXXX --profile retail-dev
```
Gateway endpoints are free. Interface endpoints bill hourly per AZ — check
`VpcEndpointType` before assuming either way.

---

## Terraform

```bash
terraform init                      # download providers, set up backend
terraform validate                  # syntax and internal consistency
terraform fmt                       # canonical formatting
terraform plan                      # what WOULD change
terraform plan -out=tfplan          # save the plan to a file
terraform apply tfplan              # apply EXACTLY that saved plan
terraform state list                # what's currently under management
terraform show tfplan               # human-readable saved plan
```

**Always `plan -out` then `apply <file>`.** Applying a saved plan executes
exactly what you reviewed — no re-planning, no drift between looking and
acting, no confirmation prompt.

```bash
terraform plan -generate-config-out=generated.tf
```
Reads live resources named in `import` blocks and writes matching HCL. Does
**not** work with `for_each` in import blocks — that's why the IAM imports
were written as explicit blocks while the S3 ones used `for_each`.

### Reading a plan summary

```
Plan: 20 to import, 1 to add, 6 to change, 0 to destroy.
```

- **import** — adoption into state, no API changes to the resource
- **add** — will be created
- **change** — will be modified in place
- **destroy** — the number that must be zero unless you intend otherwise

```bash
terraform show tfplan | grep -E "will be destroyed|must be replaced"
terraform plan 2>&1 | grep -B3 "will be destroyed"
```
Find what's being destroyed before applying. If the plan errored, these
return nothing because the diff was never printed.

### Import ID formats

| Resource | ID format |
|---|---|
| `aws_s3_bucket` and all its sub-resources | bucket name |
| `aws_iam_role` | role name |
| `aws_iam_role_policy` | `role-name:policy-name` |
| `aws_iam_role_policy_attachment` | `role-name/policy-arn` |
| `aws_iam_openid_connect_provider` | full provider ARN |
| `aws_vpc`, `aws_subnet`, `aws_route_table`, `aws_security_group` | resource ID |
| `aws_route_table_association` | `subnet-id/rtb-id` |

**Import blocks must be present for both `plan` AND `apply`.** Deleting them
after a successful plan makes Terraform try to create everything, failing
with `EntityAlreadyExists`.

---

## Glue

```bash
aws glue start-job-run --job-name retail-dev-json-to-parquet \
  --arguments '{"--year":"2010","--month":"12"}' --profile retail-dev

aws glue get-job-run --job-name retail-dev-json-to-parquet --run-id jr_XXXX \
  --query "JobRun.{State:JobRunState,Error:ErrorMessage,Seconds:ExecutionTime}" \
  --profile retail-dev

aws glue get-job-runs --job-name retail-dev-json-to-parquet \
  --query "JobRuns[].{Id:Id,State:JobRunState,Started:StartedOn,Seconds:ExecutionTime}" \
  --output table --profile retail-dev

aws glue get-job --job-name retail-dev-json-to-parquet --profile retail-dev
```

`ExecutionTime` is what you're billed on — the 82-second figure for December
2010 came from here.

---

## Lambda

```bash
aws lambda invoke --function-name retail-dev-worldbank-ingest \
  --cli-binary-format raw-in-base64-out response.json --profile retail-dev
cat response.json
```

**On Windows, do not use `/dev/stdout` as the output path** — it doesn't
exist and produces `[Errno 2] No such file or directory: '/proc/self/fd/1'`.
Write to a file instead.

```bash
aws lambda get-function --function-name NAME --profile retail-dev
aws lambda list-functions --query "Functions[].FunctionName" --output text --profile retail-dev
```

---

## CloudWatch Logs

```bash
aws logs tail /aws/lambda/retail-dev-worldbank-ingest --since 10m --profile retail-dev
aws logs tail /aws-glue/jobs/output --since 30m --profile retail-dev
aws logs tail /aws/lambda/NAME --follow --profile retail-dev
```

```bash
aws logs tail /aws-glue/jobs/output --since 1h --profile retail-dev | grep RECON
aws logs tail /aws-glue/jobs/output --since 1h --profile retail-dev | grep QUALITY_METRICS
```
The job prints these as single grep-able lines specifically so they can be
extracted this way and parsed by an observability layer later.

---

## Local data work

```bash
python convert_to_ndjson.py --input data/raw/online_retail_II.csv \
  --outdir data/json --stream-days 30
```

```bash
python -c "
import pandas as pd
df = pd.read_csv('data/raw/online_retail_II.csv', encoding='ISO-8859-1')
print(df['Country'].value_counts().to_string())
"
```
This produced the 43-country list behind the mapping table.

```bash
du -ch data/json/batch/event_date=2010-12-*/orders.json | tail -1
head -n 2 data/json/batch/event_date=2010-12-01/orders.json
```

### Profiling the source

```python
import pandas as pd
df = pd.read_csv("data/raw/online_retail_II.csv", encoding="ISO-8859-1")
df.info()
df.describe()
df['Country'].value_counts()
df[df['Quantity'] < 0].head()          # cancellations and returns
df[df['Customer ID'].isna()].shape     # missing customer IDs
df.duplicated().sum()                  # exact duplicate rows
```

The counts from this become the thresholds for dbt tests and the expected
values in the Glue job's quality metrics. Profiling before writing tests is
the right order — otherwise the thresholds are guesses.

---

## Windows specifics

```powershell
winget install Hashicorp.Terraform
winget install jqlang.jq
where.exe terraform
$env:PATH -split ';' | Select-String -Pattern 'WinGet'
```

**PATH doesn't refresh in an open VS Code window.** After installing a CLI
tool, restart VS Code entirely — a new terminal in the old window inherits
the old environment.

**Git Bash vs PowerShell:** `Get-ChildItem` and `Select-Object` are
PowerShell; `ls` and `grep` are bash. Pick one shell and stay in it. Most AWS
CLI examples assume bash quoting, which differs from PowerShell's.

---

## Things that went wrong, and what they looked like

| Symptom | Cause | Fix |
|---|---|---|
| `terraform: command not found` after installing | VS Code inherited old PATH | Restart VS Code fully |
| `Error: No configuration files` | Wrong working directory | `cd infra/terraform` |
| `GetFileAttributesEx tfplan: cannot find the file` | Ran `plan` without `-out=tfplan` | `terraform plan -out=tfplan` |
| `expected "url" to have a host` | Generated config omitted `https://` | Add the scheme by hand |
| Edit not taking effect | File unsaved in VS Code | `Ctrl+S`; verify with `grep` |
| `EntityAlreadyExists` on apply | Import blocks deleted before apply | Restore them until after apply |
| `Cannot import non-existent remote object` | Console lifecycle rule never saved | Drop the import; let Terraform create |
| `RouteAlreadyExists ... prefix-list pl-7ca54015` | Gateway endpoint already existed | Import instead of create |
| `UnauthorizedOperation: ec2:CreateTags` | Builder identity had no EC2 permissions | Attach `AmazonVPCFullAccess` |
| `ValidationError` on IAM description | Em-dash in the description string | ASCII only — IAM rejects non-Latin-1 |
| `[Errno 2] ... '/proc/self/fd/1'` | `/dev/stdout` on Windows | Write to a real file |
| Data files committed to git | No `.gitignore` at first commit | `git rm -r --cached .` then amend |
| `jq: command not found` | Bash script on Windows | Use the Python equivalent |
