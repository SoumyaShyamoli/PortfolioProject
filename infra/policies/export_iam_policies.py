#!/usr/bin/env python3
"""
Export IAM role policies to infra/policies/ for review and later Terraform work.

Cross-platform replacement for the bash+jq version — uses boto3, so it works
identically on Windows, macOS and Linux.

Why this exists: the roles were created by console click-ops. Committing the
JSON makes the IAM design reviewable in the repo, and gives you the source
material to write Terraform from later.

Usage:
    pip install boto3
    python infra/policies/export_iam_policies.py
    python infra/policies/export_iam_policies.py --prefix retail- --profile retail-dev
"""

import argparse
import json
import pathlib
import sys

import boto3
from botocore.exceptions import ClientError, NoCredentialsError, ProfileNotFound


def write_json(path: pathlib.Path, doc: dict) -> None:
    path.write_text(json.dumps(doc, indent=2) + "\n", encoding="utf-8")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--prefix", default="retail-",
                    help="Only export roles whose name starts with this")
    ap.add_argument("--profile", default=None,
                    help="AWS profile name (defaults to AWS_PROFILE / default)")
    ap.add_argument("--outdir", default="infra/policies")
    args = ap.parse_args()

    try:
        session = boto3.Session(profile_name=args.profile) if args.profile \
            else boto3.Session()
        iam = session.client("iam")
    except ProfileNotFound:
        sys.exit(f"Profile '{args.profile}' not found. Check ~/.aws/credentials")

    outdir = pathlib.Path(args.outdir)
    outdir.mkdir(parents=True, exist_ok=True)

    # Paginate — list_roles truncates at 100 by default.
    roles = []
    try:
        for page in iam.get_paginator("list_roles").paginate():
            roles += [r for r in page["Roles"]
                      if r["RoleName"].startswith(args.prefix)]
    except NoCredentialsError:
        sys.exit("No AWS credentials found. Run: aws configure --profile retail-dev")
    except ClientError as e:
        sys.exit(f"AWS error: {e}")

    if not roles:
        sys.exit(f"No roles found with prefix '{args.prefix}'.")

    manifest = [
        "# IAM policies",
        "",
        "Exported from the live account with `export_iam_policies.py`.",
        "Roles were created via the console; these files make the design",
        "reviewable and are the basis for the Terraform migration.",
        "",
    ]

    for role in sorted(roles, key=lambda r: r["RoleName"]):
        name = role["RoleName"]
        print(f"==> {name}")

        # Trust policy: who is allowed to assume this role.
        write_json(outdir / f"{name}.trust.json", role["AssumeRolePolicyDocument"])

        manifest += [f"## {name}", ""]
        if role.get("Description"):
            manifest += [f"{role['Description']}", ""]
        manifest.append(f"- Trust policy: `{name}.trust.json`")

        # Inline policies — the ones you wrote yourself. These matter most.
        for page in iam.get_paginator("list_role_policies").paginate(RoleName=name):
            for pol in page["PolicyNames"]:
                doc = iam.get_role_policy(RoleName=name, PolicyName=pol)["PolicyDocument"]
                write_json(outdir / f"{name}.{pol}.json", doc)
                print(f"    inline: {pol}")
                manifest.append(f"- Inline policy `{pol}`: `{name}.{pol}.json`")

        # Managed policies: record the ARN only. AWS-managed documents are
        # AWS-owned and would just be noise in the repo. Customer-managed ones
        # are exported in full, since you authored them.
        for page in iam.get_paginator("list_attached_role_policies").paginate(RoleName=name):
            for att in page["AttachedPolicies"]:
                arn, pname = att["PolicyArn"], att["PolicyName"]
                if arn.startswith("arn:aws:iam::aws:"):
                    manifest.append(f"- Attached AWS-managed policy: `{arn}`")
                else:
                    ver = iam.get_policy(PolicyArn=arn)["Policy"]["DefaultVersionId"]
                    doc = iam.get_policy_version(
                        PolicyArn=arn, VersionId=ver)["PolicyVersion"]["Document"]
                    write_json(outdir / f"customer-managed.{pname}.json", doc)
                    print(f"    customer-managed: {pname}")
                    manifest.append(
                        f"- Customer-managed policy `{pname}`: "
                        f"`customer-managed.{pname}.json`")

        manifest.append("")

    (outdir / "README.md").write_text("\n".join(manifest) + "\n", encoding="utf-8")

    print(f"\nDone — {len(roles)} role(s) written to {outdir}/")
    print("Account IDs will appear in the ARNs. That is not a secret, but if you")
    print("would rather not publish it, find-and-replace it with <ACCOUNT_ID>.")


if __name__ == "__main__":
    main()