# Incident — Airflow instance bootstrap, five compounding failures

- **Date:** 2026-08-27
- **Related:** ADR 0014, ADR 0015 (both amended as a result of this)
- **Status:** Resolved. Both instances bootstrap cleanly and repeatably.

## Summary

Standing up two EC2 instances to run Airflow — infrastructure that had
already been designed, reviewed, and applied via Terraform without
incident — took five separate rounds of debugging to actually boot
correctly. None of the five failures were visible from the design on
paper. Each was only found by watching a real instance fail in a real,
network-restricted environment. This is a record of what went wrong, in
the order it was found, because the *shape* of the debugging is more
instructive than any single fix

## Failure 1 — the log lied

**Symptom:** `user_data` appeared to complete in seconds. `cloud-init
status --long` reported `done`. The bootstrap log contained almost
nothing.

**Cause:** the script redirected all output with
`exec > >(tee logfile) 2>&1`. That construct launches `tee` in a
background subshell via process substitution. Under an interactive shell
this is invisible and harmless. Under `cloud-init`'s execution of
`user_data`, the parent script's exit was not reliably waited on until
that subshell finished — in practice, cloud-init considered the script
"done" almost immediately, before the real commands inside it had
meaningfully run.

**Fix:** a plain `exec > logfile 2>&1`. No subshell, no race. Confirmed by
re-running and getting a log that finally reflected reality.

**Why this mattered beyond itself:** every failure below was invisible
until this one was fixed. A logging bug that hides failures is worse than
no logging at all, because it manufactures false confidence.

## Failure 2 — no network route to PyPI

**Symptom:** `pip install` failed with `Network is unreachable`.

**Cause:** the private subnets these instances live in have no NAT
gateway and no internet gateway (ADR 0003). `dnf` had worked moments
earlier, which was briefly reassuring and slightly misleading — Amazon
Linux's own repositories are reachable via AWS-provided VPC endpoints;
PyPI is a third-party site with no such endpoint. There is no route out
of these subnets to the public internet, full stop.

**Fix:** ADR 0015 — pre-download every Python package on a machine with
internet, upload to S3, install from there with `--no-index
--find-links`, over the free S3 gateway endpoint the platform already
had.

## Failure 3 — a resolver conflict that turned out to be two different bugs

**Symptom:** building the wheelhouse via `pip download` with
`--platform`/`--python-version` cross-resolution flags hit
`ResolutionImpossible`: Airflow needs `dill>=0.2.2`, the constraints file
pins `dill==0.3.1.1`, and — critically — no wheel exists for that exact
old `dill` pin under the cross-resolution target at all.

Multiple attempts to route around this (splitting Airflow from its
providers, splitting providers from dbt/Snowflake) narrowed the symptom
but did not fix the underlying problem: **`pip download`'s cross-platform
resolution is unreliable for old, narrowly-pinned transitive
dependencies**, independent of how the command is split.

**Fix:** stop cross-resolving. Build the wheelhouse natively — on a
throwaway EC2 instance running the actual target OS and Python version —
rather than emulating the target from a different machine. This is the
same pattern AWS's own guidance recommends for Lambda layers targeting a
different platform than the build machine.

## Failure 4 — a silent, successful-looking dependency upgrade (twice)

**Symptom:** the bootstrap log showed no errors, reached
`systemctl start`, and later inspection showed `apache-airflow 3.3.1`
installed — not `2.10.5`.

**Cause:** with providers downloaded unconstrained, Airflow was present
only as a transitive dependency (`apache-airflow-providers-amazon
>=2.9.0`), and pip picked the newest version satisfying that minimum — a
different major version, with a materially different architecture,
installed with zero errors at any point.

**First fix attempt, still incomplete:** reapplying the constraints file
to the providers download stopped the jump to 3.x but landed on `2.11.0`
— a different 2.x minor, not the intended 2.10.5. The constraints file
pins *dependencies* for a target release; it does not itself force the
target package's own version when that package is only present
transitively.

**Actual fix:** state the exact version explicitly on every command that
touches the dependency graph, and verify it mechanically rather than
trust it:

- `build_wheelhouse.sh` now refuses to upload if the wheelhouse contains
  anything other than exactly the target Airflow version.
- `airflow_bootstrap.sh.tpl` runs `airflow version` after install and
  exits with a clear `FATAL` if it doesn't match, before configuration or
  systemd ever run.

**The lesson:** "I applied the constraints file" and "I pinned the
version" are not the same claim. The first limits what a resolver *may*
pick from candidates already in play; it does not by itself put a
specific version *in play* if nothing explicitly requested it. This drift
happened twice, in two different specific ways, before that distinction
was made explicit and checked mechanically.

## Failure 5 — the constraints file fetch, not covered by --no-index

**Symptom:** with packages installing correctly offline, `pip install
--constraint <url>` still failed with `Network is unreachable` — to
`raw.githubusercontent.com`, not `pypi.org`.

**Cause:** `--no-index`/`--find-links` govern where pip looks for
*packages*. `--constraint <url>` is a separate HTTP fetch pip makes to
read the pin list itself, and that fetch is not covered by `--no-index`
at all. Same underlying network boundary as Failure 2, hit again via a
URL that didn't look like a package source and so wasn't recognised as
the same class of problem the first time.

**Fix:** download the constraints file once during the wheelhouse build,
ship it as a local file (`constraints.txt`) alongside the packages, and
reference that local path — never a URL — in every `--constraint` flag
from then on.

## Failure 6 — a configuration mechanism that doesn't exist

**Symptom:** `tee: /opt/airflow/airflow.cfg.d/executor.cfg: Permission
denied`, immediately after `db init` succeeded.

**Cause:** the script wrote executor and database configuration to a
directory it assumed Airflow would scan — `airflow.cfg.d/` — following
the pattern of tools like nginx or systemd that do work that way. Airflow
does not; there is no such mechanism. The immediate cause of the failure
was a mundane ownership bug (the directory was created root-owned, then
written to as a different user), but fixing only that would have left a
script that "succeeds" while silently never configuring the executor at
all.

**Fix:** Airflow's actual override mechanism —
`AIRFLOW__SECTION__KEY` environment variables — set directly on both
systemd units, consistent with how other environment variables were
already being passed to them.

## What actually fixed things, in the order it happened

1. Plain log redirect, not `tee`/process substitution.
2. Pre-built wheelhouse in S3, installed with `--no-index`, instead of
   reaching PyPI directly.
3. Wheelhouse built natively on a throwaway same-OS instance, not
   cross-resolved from a different platform.
4. Every Airflow-touching install command states the target version
   explicitly; both the build script and the bootstrap script verify the
   result mechanically rather than trusting the constraint alone.
5. The constraints file is a local, shipped artifact, not a URL fetched
   at install time.
6. Airflow configuration set via systemd `Environment=` variables, not a
   file-based mechanism that was never real.

## Why this is worth keeping, not just fixing and forgetting

Every one of these six failures produced either silence or a plausible-
looking success before the real problem surfaced. None were caught by
review, by planning, or by the first fix attempt — several needed a
second, more careful fix after the first one only narrowed the symptom.
The common thread is that a design can look complete and be reviewed
carefully and still contain assumptions that only a real, restricted
environment will actually test. "It compiles" and "the log has no
errors" were both, at various points here, insufficient evidence that
something worked — the fix, each time, was to check the actual outcome
mechanically rather than infer it from the absence of a visible failure.
