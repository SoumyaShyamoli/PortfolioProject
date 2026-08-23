# IAM additions for CI/CD

Add these statements to the existing policies in `iam.tf`.

## 1. State bucket access — both deploy roles

Terraform needs to read state and write the lock file. Without this, `init`
fails on the backend.

```hcl
      {
        Sid    = "TerraformState"
        Effect = "Allow"
        Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
        Resource = [
          "arn:aws:s3:::sd-retail-tfstate-009073574996-eu-west-2-an/platform/terraform.tfstate",
          # use_lockfile writes a sibling object with a .tflock suffix
          "arn:aws:s3:::sd-retail-tfstate-009073574996-eu-west-2-an/platform/terraform.tfstate.tflock",
        ]
      },
      {
        Sid      = "TerraformStateList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = ["arn:aws:s3:::sd-retail-tfstate-009073574996-eu-west-2-an"]
      },
```

Scoped to the specific state key, not the whole bucket — so a second
project's state in the same bucket would be unreachable from these roles.

## 2. Read-only for planning — dev deploy role only

`terraform plan` must read every resource it manages to compute a diff. The
managed policy is the pragmatic choice here; enumerating every `Describe*`
and `Get*` action across S3, IAM, EC2, Glue and Lambda by hand would be long
and would break every time a resource type is added.

```hcl
resource "aws_iam_role_policy_attachment" "dev_cicd_readonly" {
  role       = aws_iam_role.dev_cicd_deploy.name
  policy_arn = "arn:aws:iam::aws:policy/ReadOnlyAccess"
}
```

**Worth being clear about what this grants.** `ReadOnlyAccess` covers the
whole account, including reading S3 object *contents*. On a platform whose
raw layer contains customer identifiers, that is a real consideration.

For this project it is acceptable: the data is a public research dataset, the
role is only assumable from this repository via OIDC, and sessions are
one hour. On a platform with genuine PII the right answer would be a
custom read-only policy scoped to the resource types Terraform manages, with
`s3:GetObject` excluded.

Note this attaches to the **dev** role only. The prod role does not plan — it
only uploads artifacts.

## 3. Nothing extra for the prod role

The existing policy already covers what the deploy workflow does: `PutObject`
on the script prefix and `StartJobRun`. It deliberately cannot apply
infrastructure.

## Verifying it works

The OIDC round trip is the part most likely to fail, and the errors are
unhelpful. Check in this order:

1. **`Not authorized to perform sts:AssumeRoleWithWebIdentity`** — the trust
   policy's `sub` condition does not match. For a PR from a branch the claim
   is `repo:OWNER/REPO:ref:refs/heads/BRANCH`; the dev role uses a wildcard,
   the prod role requires exactly `refs/heads/main`.

2. **`Credentials could not be loaded`** — `permissions: id-token: write` is
   missing from the workflow. This is the most common cause.

3. **`No OpenIDConnect provider found`** — the provider ARN in the trust
   policy does not match the one in the account.

To test without opening a pull request, push a branch and use
`workflow_dispatch` on the deploy workflow — the dev job will run and fail
fast if the trust is wrong.
