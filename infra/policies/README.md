# IAM policies

Exported from the live account with `export_iam_policies.py`.
Roles were created via the console; these files make the design
reviewable and are the basis for the Terraform migration.

## retail-cicd-deploy-role

CICD PROD

- Trust policy: `retail-cicd-deploy-role.trust.json`
- Inline policy `retail-cicd-deploy-role`: `retail-cicd-deploy-role.retail-cicd-deploy-role.json`

## retail-dev-cicd-deploy-role

CICD fo Dev

- Trust policy: `retail-dev-cicd-deploy-role.trust.json`
- Inline policy `retail-dev-cicd-deploy-rolePolicy`: `retail-dev-cicd-deploy-role.retail-dev-cicd-deploy-rolePolicy.json`

## retail-dev-pipeline-exec-role

Allows Glue to call AWS services on your behalf. 

- Trust policy: `retail-dev-pipeline-exec-role.trust.json`
- Inline policy `retail-dev-pipeline-exec-rolePolicy`: `retail-dev-pipeline-exec-role.retail-dev-pipeline-exec-rolePolicy.json`
- Attached AWS-managed policy: `arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole`

## retail-human-admin-role

Human Admin Role

- Trust policy: `retail-human-admin-role.trust.json`
- Inline policy `retail-human-admin-role`: `retail-human-admin-role.retail-human-admin-role.json`

## retail-prod-pipeline-exec-role

Allows Glue to call AWS services on your behalf. 

- Trust policy: `retail-prod-pipeline-exec-role.trust.json`
- Inline policy `retail-prod-pipeline-exec-rolePolicy`: `retail-prod-pipeline-exec-role.retail-prod-pipeline-exec-rolePolicy.json`
- Attached AWS-managed policy: `arn:aws:iam::aws:policy/service-role/AWSGlueServiceRole`

