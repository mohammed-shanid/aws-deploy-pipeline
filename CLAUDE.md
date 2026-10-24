# CLAUDE.md

Instructions for Claude Code sessions in this repository. Keep this file short: detailed procedures live in `.claude/skills/` and `docs/architecture/`.

> Sections marked `FILL` are completed by the Phase 1 audit (see PROMPTS.md) from the real repository. Until then, treat them as unknown. Do not guess them.

## Purpose

This repository contains an application and the infrastructure that runs it on AWS:
Terraform (network, compute, IAM, state), Ansible (host configuration), Docker (runtime), GitHub Actions (CI/CD), CloudWatch (monitoring).

The goal is a small system that one engineer can build, deploy, break, diagnose and recover — not maximum scale.

## Application (FILL)

> Audit 2026-10-24: the repository and its remote contain no application code. Every field below is blocked until the source is added.

- Runtime and version: FILL
- Entry point / start command: FILL
- Health endpoint: FILL (if none exists, adding one is a planned change, not an assumption)
- External integrations and the secrets they need: FILL
- Existing tests and how to run them: FILL

## Architecture (summary)

```
GitHub Actions ──OIDC──> AWS IAM role (scoped to this repo + main branch)
      │ build → test → Trivy scan → push to ECR (tag = git SHA)
      │ deploy via SSM Run Command (no inbound SSH from CI)
      ▼
EC2 (public subnet, Ubuntu LTS, instance role, IMDSv2 only)
  Nginx :443 (Let's Encrypt) → app container on 127.0.0.1
  CloudWatch agent → metrics + logs → alarms → SNS email
```

Full detail: `docs/architecture/architecture.md`. Decisions: `docs/architecture/adr/`.

## Repository layout

```
app source           FILL (existing layout, do not restructure)
infra/terraform/     bootstrap/ (state bucket, budget) and envs/<env>/ + modules/
infra/ansible/       inventory, playbooks, roles
.github/workflows/   CI and deploy pipelines
docs/architecture/   architecture, security, deployment, cost, ADRs, diagrams (Mermaid)
docs/incidents/      incident write-ups (symptom, commands, root cause, fix)
.claude/skills/      Claude Code skills for repeatable workflows
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

- Terraform ≥ 1.10 with S3 remote state, native S3 locking (`use_lockfile = true`), versioning and encryption on the state bucket. Verify against current Terraform docs before writing the backend block.
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
4. Diff reviewed for secrets and unrelated edits.
5. Summary: what changed, what was verified, what is blocked, and the human actions still required.

## Skills

See `.claude/skills/`. Use them when their description matches the task:
- `infra-change` — any Terraform or Ansible change (plan-only workflow)
- `deploy-and-rollback` — release, verify, roll back
- `incident-drill` — break-and-fix exercises and write-ups

