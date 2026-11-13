# CLAUDE.md

Instructions for Claude Code sessions in this repository. Keep this file short: detailed procedures live in `docs/architecture/` (and later in `.claude/skills/`).

> Sections marked `FILL` are completed by the Phase 1 audit (see PROMPTS.md) from the real repository. Until then, treat them as unknown. Do not guess them.

## Purpose

This repository contains an application and the infrastructure that runs it on AWS:
Terraform (network, compute, IAM, state), Ansible (host configuration), Docker (runtime), GitHub Actions (CI/CD), CloudWatch (monitoring).

The goal is a small system that one engineer can build, deploy, break, diagnose and recover — not maximum scale.

Repository: `mohammed-shanid/aws-deploy-pipeline` on GitHub. Deploys come only from `main`.

## Application (FILL)

> Audit 2026-10-24: the repository and its remote contain no application code. Every field below is blocked until the source is added.

- Runtime and version: FILL
- Entry point / start command: FILL
- Health endpoint: FILL (if none exists, adding one is a planned change, not an assumption)
- External integrations and the secrets they need: FILL
- Existing tests and how to run them: FILL

## Architecture (summary)

Target design, not deployed yet. Must match the ADRs; change both together.

```
GitHub Actions ──OIDC──> deploy role (StringEquals sub = repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main)
      │ lint → test → build → Trivy → push to ECR (immutable tag = full git SHA)            ADR 0003
      │ ssm:SendCommand on one custom deploy document (only param: 40-hex sha) and          ADR 0002
      │ one instance. Not AWS-RunShellScript, no SSH from CI
      ▼
EC2 t3.small in one public subnet, Elastic IP. No ALB, no NAT, no private subnets           ADR 0001
  Ubuntu LTS, IMDSv2 required with hop limit 1, encrypted gp3 root, least-privilege instance role
  SG + ufw: 80/443 in, 22 closed (shell via SSM Session Manager)
  Nginx :443 (Let's Encrypt) → active slot 127.0.0.1:8001 or :8002 → app container :8000
  Deploy script: start inactive slot → health gate → switch Nginx; on failure the old slot keeps serving.
    State in /opt/app/state/{current,previous}
  DEMO_SECRET: SSM Parameter Store SecureString, created by the human, read at container start  ADR 0005
  CloudWatch agent → metrics + logs → alarms → SNS email
Terraform state: S3 backend with use_lockfile (no DynamoDB); bootstrap/ uses local state     ADR 0004
```

Full detail: `docs/architecture/architecture.md`. Decisions: `docs/architecture/adr/`.

## Repository layout

```
app source           FILL (existing layout, do not restructure)
infra/terraform/     bootstrap/ (state bucket, budget) and envs/<env>/ + modules/
infra/ansible/       inventory, playbooks, roles
infra/tests/         tests of the tests (Terraform mutation check); outside infra/terraform so checkov skips its fixture
.github/workflows/   CI and deploy pipelines
docs/architecture/   architecture, security, deployment, cost, ADRs, diagrams (Mermaid)
docs/incidents/      incident write-ups (symptom, commands, root cause, fix)
.claude/skills/      Claude Code skills for repeatable workflows (Later)
```

Only create directories when the phase that needs them starts.

## Commands

Only list commands here after they have been run successfully in this repo.

| Purpose | Command |
|---|---|
| App tests | FILL |
| App lint | FILL |
| Terraform format / validate | `terraform fmt -check -recursive infra/terraform` · `terraform -chdir=infra/terraform/envs/<env> validate` |
| Terraform plan | `terraform -chdir=infra/terraform/envs/<env> plan -out=tfplan` |
| Terraform guardrail mutation check | `.venv/bin/python infra/tests/terraform_mutation/mutate.py` (~3 min) |
| Ansible lint / dry run | `ansible-lint infra/ansible` · `ansible-playbook ... --check --diff` |
| Image build / scan | FILL after Dockerfile exists |
| Bring up / tear down | `make up` / `make destroy` (once Makefile exists) |

## Hard rules

These are not negotiable. If a task seems to require breaking one, stop and ask.

1. **Never run `terraform apply`, `terraform destroy`, `aws ... delete*`, IAM policy changes, or DNS changes.** Produce the plan or exact command, show the impact, and let the human run it.
2. **No long-lived AWS access keys** anywhere: not in code, CI secrets, `.env` files, or on the instance. CI uses OIDC; the instance uses its role.
3. **Never print, log, commit or echo secrets.** App secrets live in SSM Parameter Store (SecureString) and are read at container start. `.env` files are gitignored; commit only `.env.example` with placeholder values.
4. **No wildcard IAM** (`"Action": "*"` or `"Resource": "*"` on write actions) unless an AWS service genuinely requires it. Document the exception inline.
5. **Security group ingress:** 80 and 443 only from the internet. SSH (22) only from the operator's /32, or closed entirely in favour of SSM Session Manager. Never `0.0.0.0/0` on 22.
6. **Never disable a security check** (Trivy, lint, tfsec/checkov, TLS verification) to make a pipeline pass. Fix it, or document an explicit, dated exception with severity.
7. **No NAT Gateway, ALB, EKS, RDS, or extra managed services** without an ADR showing a concrete requirement and the cost.
8. **Do not modify existing tests to make them pass** unless the test is demonstrably wrong; explain why if so.
9. **Do not restructure or refactor the application** beyond what deployment requires (e.g. a health endpoint, reading config from env).

## Infrastructure-as-code standards

- Terraform ≥ 1.11 (`use_lockfile` was experimental in 1.10, ADR 0004) with S3 remote state, native S3 locking (`use_lockfile = true`), versioning and encryption on the state bucket. Verify against current Terraform docs before writing the backend block.
- Pin provider versions; commit `.terraform.lock.hcl`.
- `bootstrap/` (state bucket, budget alert) uses local state and is applied once, before anything else.
- Tag every resource: `Project`, `Environment`, `Owner`, `ManagedBy=terraform`.
- Every change ends with `fmt`, `validate`, and a saved `plan` whose summary is reported to the human.
- Ansible must be idempotent: a second run reports `changed=0`.

## Containers and deployment

- Multi-stage build, pinned base image (digest or exact version, never `latest`), non-root user, `HEALTHCHECK`, graceful shutdown on SIGTERM.
- Release tag = full git SHA. Never deploy a mutable tag.
- Deploy = pull new tag → start → health check → switch; on failure, restart previous tag automatically and fail the pipeline.
- The deploy script on the host records the current and previous tags so rollback never depends on CI being available.

## Testing and verification

- Run the app's existing tests before and after changes; report both results.
- A phase is not done until its verification step (in PROMPTS.md) has actually been run and its output shown.
- Never state that something is deployed, scanned, passing or working without command output that shows it.
- Label results as: tested and passed / implemented, not tested / blocked (with reason).

## Git workflow

- One branch per phase: `infra/<phase-name>`. Small commits with imperative messages.
- Before each commit: `git diff --staged` reviewed for secrets, unrelated changes and generated files.
- Never force-push, rewrite history, or delete branches.

## Documentation

- Update `docs/architecture/` in the same change as the infrastructure it describes.
- Record a significant decision as an ADR: context, decision, alternatives, consequences, what would change it.
- Cost notes must cite the pricing page and date checked; label every figure as an estimate.

## Definition of done (per phase)

1. Changes implemented on the phase branch.
2. Verification commands run; output shown.
3. Docs updated to match what exists.
4. README status updated: the "What's proven so far" table and the Roadmap status column, with evidence links only for what was actually run.
5. Diff reviewed for secrets and unrelated edits.
6. Summary: what changed, what was verified, what is blocked, and the human actions still required.

## Skills (Later)

Not created yet; deferred (PROMPTS.md Phase 3). Until they exist, follow the matching procedure directly:
- `infra-change`: fmt → validate → checkov → `plan -out` → summarise → hand the apply to the human
- `deploy-and-rollback`: `docs/architecture/deployment.md`
- `incident-drill`: write-ups in `docs/incidents/` (symptom, commands with real output, root cause, fix, prevention)

