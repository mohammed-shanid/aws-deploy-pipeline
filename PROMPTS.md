# Claude Code prompts — AWS deployment pipeline

## How to use these

- Put `CLAUDE.md` in the repo root first.
- Run **one prompt per session** and start a fresh session (`/clear`) between phases. One giant prompt that covers everything burns context, and the later phases get done badly or are marked "done" without verification. Phase gates stop that.
- Run Phase 1 in **plan mode**, which is read-only.
- Do not start a phase until the previous phase's **Gate** has passed. You check the gate yourself, not Claude.
- Anything that creates, changes or deletes AWS resources is run **by you** in your terminal, after reading the plan.

Order: 0 → 1 → 2 → 3b → 4 → 5 → 6 → 7 → 8 → 9 → 10. Phase 3 (skills) is Later. Phases 4–9 each produce something real you can show.

From Phase 5 on, each phase must pass its **local** harness check (Phase 3b, `docs/architecture/deployment.md` §6) before anything is run against AWS.

---

## Phase 0 — Guardrails (5 min)

```
Read CLAUDE.md. Create .claude/settings.json with permission deny rules that enforce its hard rules, so they don't rely on instructions alone:
deny Bash for: terraform apply, terraform destroy, terraform state rm, terraform import, aws * delete*, aws iam *, aws route53 change-resource-record-sets, git push --force, git reset --hard.
Check the current Claude Code docs for the exact permission-rule syntax before writing it. Don't guess.
Also add/extend .gitignore for: .env, *.tfstate*, .terraform/, tfplan, *.pem.
Show me the files. Do not change anything else.
```

**Gate:** start a new session and ask Claude to run `terraform apply`. The settings file should block it.

---

## Phase 1 — Audit (read-only, plan mode)

```
Audit this repository. Do not modify any files.

Inspect: structure, runtime and versions, entry points, dependencies, config and env vars (names only, never values), external integrations, tests, existing Dockerfiles, CI workflows and any infrastructure files, and recent git history.

Then:
1. Run the existing test suite and report the exact result. If it can't run, explain why.
2. Tell me whether the app exposes an HTTP endpoint suitable for a health check. If not, say what minimal change would add one.
3. List every secret the app needs at runtime, by name.
4. List security issues you found (committed secrets, unpinned deps, etc.) with severity.
5. Write the FILL sections of CLAUDE.md as a proposed diff, using only verified facts.

Output: current-state summary, the CLAUDE.md diff, blockers, and assumptions I need to confirm. Keep it under one screen where possible.
```

**Gate:** you've read the findings, the tests ran (or you know why not), and you've approved the CLAUDE.md diff.

> If the audit shows the app is a background worker with no HTTP interface (e.g. the enquiry monitor), stop here. Nginx, TLS and an HTTPS uptime check no longer have a requirement. Ask Claude to redesign Phase 2 around a worker: no public ingress, a heartbeat metric, and an alarm when the heartbeat goes missing.

---

## Phase 2 — Architecture and decisions (docs only)

```
Using the audit results and CLAUDE.md, write the architecture documents. No infrastructure code yet.

Create:
- docs/architecture/architecture.md: components, data flow, trust boundaries, assumptions, trade-offs
- docs/architecture/diagrams/architecture.mmd (Mermaid)
- docs/architecture/security.md: threats, IAM design, network exposure, secrets flow, open risks
- docs/architecture/deployment.md: release flow, rollback procedure, manual break-glass steps
- docs/architecture/cost-estimate.md: cost drivers only; mark every number as an estimate with the AWS pricing page and date checked
- docs/architecture/adr/ — one ADR each for:
  0001 single EC2 in a public subnet, no ALB, no NAT Gateway
  0002 deploy via SSM Run Command, not SSH from CI
  0003 ECR as the image registry
  0004 Terraform S3 backend with native lockfile locking (verify the current Terraform version supports it)
  0005 app secrets in SSM Parameter Store SecureString

Each ADR should cover: context, decision, alternatives rejected and why, consequences, and what would make us revisit it.

Challenge any of these decisions that doesn't fit what the audit found. Don't just document them.
Explain why private subnets exist in this design when nothing runs in them, or recommend dropping them.
```

**Gate:** you can explain each ADR out loud without reading it. If you can't, ask about it before moving on.

---

## Phase 3 — Skills (Later)

Deferred on 2026-10-28; run it after Phase 10. Until then, a prompt below that says "Use the <name> skill" means: follow that procedure as listed in CLAUDE.md, § Skills (Later).

```
Check the installed Claude Code version and the current skills documentation. Then create three project skills under .claude/skills/<name>/SKILL.md, using the correct frontmatter (name, description):

1. infra-change — for any Terraform or Ansible change: fmt → validate → tflint/checkov if installed → plan -out → summarise adds/changes/destroys → STOP and hand the apply command to the human. Include what to do when a plan shows an unexpected destroy.
2. deploy-and-rollback — how a release is triggered and verified, how the automatic rollback works, and how to roll back manually from the instance via SSM if CI is down.
3. incident-drill — run one controlled failure, capture the symptom, diagnostic commands with their real output, root cause, fix and prevention, and write it up in docs/incidents/NNNN-<slug>.md.

Each skill needs: when to use it, prerequisites, steps, verification, failure handling, security constraints, and completion criteria. Keep each under ~80 lines. Do not create a SKILLS.md index. CLAUDE.md already lists them.
```

**Gate:** in a fresh session, ask "what skills do you have?" and confirm all three are listed.

---

## Phase 3b — Local test harness (no AWS)

```
Add a local test harness before any AWS work, and update PROMPTS.md so Phases 5–8 use it:
1. Terraform: add `terraform test` files using mock_provider for the dev env, asserting: required tags on all resources, no ingress on 22, IMDSv2 required, EBS encrypted, OIDC trust subject matches the repo. Add checkov (or trivy config) as a CI step. Verify the mock_provider syntax against current Terraform docs.
2. Ansible: a local Ubuntu 24.04 target using OrbStack (check `orb` is installed), with an inventory file for it. Each role must pass two runs with changed=0 on the second. Use a self-signed cert locally; keep Let's Encrypt for the AWS environment only.
3. Deploy/rollback: a local test that deploys a good image SHA, then a deliberately broken one, and asserts the previous container is still serving /version.
Document in docs/architecture/deployment.md which checks run locally and which only run on AWS, and why.
Don't touch any AWS account.
```

Result (2026-10-24): the tests were written before the code they test, so they are the spec for Phases 5–8. Layout: `infra/terraform/envs/dev/tests/`, `infra/terraform/checkov/`, `.checkov.yaml`, `infra/ansible/inventories/local/`, `infra/ansible/tests/`, `.github/workflows/ci.yml` (`iac` job), `requirements-infra.txt`.

**You do:** install OrbStack and open it once. Then run `python3.12 -m venv .venv-infra && .venv-infra/bin/pip install -r requirements-infra.txt`.

**Gate:** `infra/ansible/tests/orb_machine.sh` creates the machine, reports `ubuntu 24.04`, and the Ansible ping succeeds. deployment.md §6.4 records how the harness itself was verified.

---

## Phase 4 — Terraform bootstrap: budget + state

```
Use the infra-change skill.

Create infra/terraform/bootstrap/ (local state) containing:
- an AWS Budget with an email alert at a low monthly threshold (I'll supply the amount and email as variables, not hardcoded)
- the S3 state bucket: versioning, SSE, public access block, TLS-only bucket policy, prevent_destroy

Pin the Terraform and AWS provider versions. Variables go in a .tfvars.example; the real .tfvars is gitignored.
Run fmt, validate and plan with my AWS profile (AWS_PROFILE is set in my shell; never ask me for keys). Show the plan summary and stop.
```

**You run:** `terraform -chdir=infra/terraform/bootstrap apply tfplan`

**Gate:** the budget shows in the AWS console, and the state bucket has versioning on and public access blocked.

---

## Phase 5 — Terraform: network, EC2, IAM, ECR, OIDC

```
Use the infra-change skill.

Create infra/terraform/envs/dev/ using the S3 backend from Phase 4, with small modules only where they remove real duplication:
- VPC, one public subnet (plus private subnets only if Phase 2 justified them), IGW, route tables
- security group: 80/443 from anywhere; 22 only from var.operator_cidr, defaulting to closed
- EC2: Ubuntu LTS AMI from a data source (not a hardcoded ID), IMDSv2 required, encrypted root volume, instance profile with only: AmazonSSMManagedInstanceCore, ECR pull for this repo, CloudWatch agent, read of /<project>/<env>/* in Parameter Store
- Elastic IP
- ECR repo: immutable tags, scan on push, lifecycle policy keeping the last N images
- GitHub OIDC provider and a deploy role whose trust policy is restricted to repo:<owner>/<repo>:ref:refs/heads/main, with permissions only for ECR push to this repo and ssm:SendCommand to this instance

The local harness is the spec. Read infra/terraform/envs/dev/tests/guardrails.tftest.hcl first and use the resource addresses in its header (tags via local.common_tags → provider default_tags; IAM JSON via jsonencode()). Do not edit the tests to get to green.
Before any plan with credentials, these must pass and their output must be shown:
- terraform -chdir=infra/terraform/envs/dev init -backend=false && terraform -chdir=infra/terraform/envs/dev test
- .venv-infra/bin/checkov from the repo root. For each finding, fix it or add an inline `#checkov:skip=<ID>: <reason>, <date>` with the reason (e.g. CKV_AWS_260, port 80 open by design). Never add a skip in .checkov.yaml.
Then run plan, and run the tags_all check on the saved plan (deployment.md §6.2).

For every IAM policy, explain each action and why it's needed. Run plan and stop.
```

**You run:** apply. Then `aws ssm describe-instance-information` and confirm the instance shows as Online.

**Gate:** `terraform test` and checkov pass locally and in the `ci` workflow on the PR. The `tags_all` plan check prints nothing. You can open an SSM session to the instance, and port 22 is closed or limited to your IP.

---

## Phase 6 — Ansible host configuration

```
Use the infra-change skill.

Create infra/ansible/. Use SSM as the connection method if practical (check the current community.aws aws_ssm plugin requirements); otherwise SSH from my /32 only. Roles:
- base: non-root deploy user, unattended security upgrades, timezone, logrotate for app and Nginx logs
- ssh: key-only, no root login, no password auth (validate sshd config before reload so I can't lock myself out)
- firewall: ufw allowing only 80, 443 (and 22 only if used)
- docker: Docker from the official repo, pinned major version; deploy user can run containers
- nginx + certbot: reverse proxy to 127.0.0.1:<app port>, Let's Encrypt cert, auto-renew timer, HTTP→HTTPS redirect, sensible security headers

Domain and email are variables. Run ansible-lint and --check --diff. Show me the commands to run for real, then stop.
Note: Let's Encrypt no longer sends expiry warning emails (verify this). Phase 9 needs its own certificate-expiry check.

Develop against the local OrbStack target first (infra/ansible/inventories/local). Every variable in its group_vars must also be defined for AWS.
- TLS: `tls_mode: selfsigned` locally (key and cert at tls_key_path/tls_cert_path, app_domain as a SAN, generated idempotently), `letsencrypt` on AWS only. The nginx role must fail if tls_mode is letsencrypt while env_name is local.
- Write /etc/app/deploy.env from the deploy.env variables (deployment.md §2), even though the deploy script itself comes in Phase 8.
- Run `infra/ansible/tests/idempotence.sh --fresh`, then `--role <name>` for each role, and show the output. The second run of each must report changed=0. Do not hide changes with `changed_when: false` on tasks that really change state.
Only after that, run --check --diff against AWS.
```

**You run:** `infra/ansible/tests/idempotence.sh --fresh` (local), then the AWS playbook twice.

**Gate:** the local harness passes for site.yml and for each role on its own. On AWS, the second run reports `changed=0`, and `curl -I https://<domain>` returns the Nginx response with a valid cert.

---

## Phase 7 — Docker done properly

```
Containerise the application without changing its behaviour.

- multi-stage build; pinned base image; non-root user; HEALTHCHECK against the health endpoint; handles SIGTERM
- add a health endpoint only if the audit found none; add a test for it
- .dockerignore excludes .git, .env, tests artefacts, node_modules/.venv as appropriate
- config from env vars; secrets never baked into the image or build args

Build locally, run it, hit the health endpoint, run the existing tests, run `trivy image` and report HIGH/CRITICAL findings with a fix or a justified exception for each. Report the final image size.
The Dockerfile lives at the repo root. The local rollback test builds infra/ansible/tests/fixtures/broken on top of this image, so `python` must be on PATH and the app must honour HOST/PORT. Check that the fixture image builds.
```

**Gate:** the container starts, it is healthy, it runs as non-root (`docker exec <c> id`), and the Trivy results are documented. The image also builds inside the OrbStack machine (`orb -m adp-noble docker build <repo path>`), since the Phase 8 rollback test builds it there.

---

## Phase 8 — CI/CD with OIDC and automatic rollback

```
Use the deploy-and-rollback skill.

Create GitHub Actions workflows. Extend existing ones rather than duplicating them: ci.yml already has the `iac` job from Phase 3b; add jobs to it.
- ci.yml on PRs: lint, test, docker build, Trivy (fail on CRITICAL), terraform fmt/validate
- deploy.yml on main: same checks → build → push to ECR tagged with the full git SHA → deploy via aws ssm send-command
- pin every third-party action to a commit SHA; least-privilege `permissions:` block per job; id-token: write only on the job that assumes the AWS role

On-instance deploy script (installed by Ansible): pull the image by SHA; fetch secrets from Parameter Store into the container env without writing them to disk or logs; start the new container; poll its health for N seconds; on success, switch Nginx/upstream and record current/previous tags; on failure, keep or restore the previous container and exit non-zero so the workflow fails.

The deploy script must meet the contract in docs/architecture/deployment.md §2 and the header of infra/ansible/tests/deploy_rollback_inner.sh: inputs from /etc/app/deploy.env (REGISTRY_AUTH ecr|none, SECRETS_SOURCE ssm|none), state in /opt/app/state/{current,previous}, label adp.app=aws-deploy-pipeline, HEALTH_TIMEOUT_SECONDS override. The local/AWS difference must be limited to those config switches, not separate code paths for the gate and switch logic.
Before any AWS deploy: re-run infra/ansible/tests/idempotence.sh (the script is installed by Ansible), then infra/ansible/tests/deploy_rollback.sh, and show both outputs. Do not edit the test to get to green.

Before I merge, show the exact trust policy the workflow will assume. Explain how to test the rollback deliberately.
```

**Gate:** `deploy_rollback.sh` passes locally (both broken releases rejected, zero failed requests). Then one green deploy on AWS, then a deliberately broken commit (a health endpoint returning 500) that the pipeline **rolls back automatically** while the site stays up. Save the run links.

---

## Phase 9 — Monitoring and alerting

```
Use the infra-change skill.

Add:
- CloudWatch agent config (via Ansible): mem_used_percent, disk_used_percent for /, Docker and Nginx logs shipped to log groups with a retention period set
- SNS topic with my email subscription (variable)
- alarms: CPU, memory, disk > 80%, instance status check failed, and an HTTPS uptime check (compare a Route 53 health check with a CloudWatch Synthetics canary on cost and capability, recommend one, and record it as an ADR)
- certificate-expiry alarm (< 14 days)

Show the plan and stop. After I apply, give me commands to trigger each alarm safely, so I can confirm the emails arrive.
```

**Gate:** you received at least the disk and uptime alarm emails for real.

---

## Phase 10 — Break it on purpose, then finish the README

Two drills, one session each, using the incident-drill skill:

```
Use the incident-drill skill for: <hung app | 443 blocked in the security group>.
Tell me exactly what you'll do to cause the failure and how to undo it before doing anything. Wait for my OK.
For the hung app, the process must stay up with its port open but stop answering, so it's not the same as a crash. Show what detects it (Docker health status, the watchdog, the uptime alarm) and how long each takes.
For the security-group change, give me the command to run myself.
```

Later: disk full and expired certificate. For the expired cert, don't try to make a real Let's Encrypt cert expire. Propose a safe simulation (e.g. a short-lived self-signed cert on a test subdomain) and say what it does and doesn't prove.

Then:

```
Update README.md (it already exists; keep its sections): add make up / make destroy (create the Makefile wrapping the existing commands; destroy must print the plan and require typed confirmation), link every docs/incidents/ write-up, and update the "What's proven so far" and Roadmap tables with evidence links.
Finally, review the full diff since main for secrets, wildcard IAM, open ports and unpinned versions. List anything still unverified.
```

**Gate:** someone else could clone the repo, read the README, and understand both how it works and how it fails.
