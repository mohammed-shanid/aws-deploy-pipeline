# Claude Code prompts — AWS deployment pipeline

## How to use these

- Put `CLAUDE.md` in the repo root first.
- Run **one prompt per session** and start a fresh session (`/clear`) between phases. One giant prompt that covers everything burns context, and the later phases get done badly or are marked "done" without verification. Phase gates stop that.
- Run Phase 1 in **plan mode**, which is read-only.
- Do not start a phase until the previous phase's **Gate** has passed. You check the gate yourself, not Claude.
- Anything that creates, changes or deletes AWS resources is run **by you** in your terminal, after reading the plan.

Order: 0 → 1 → 2 → 3 → 4 → 5 → 6 → 7 → 8 → 9 → 10. Phases 4–9 each produce something real you can show.

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

## Phase 3 — Skills

```
Check the installed Claude Code version and the current skills documentation. Then create three project skills under .claude/skills/<name>/SKILL.md, using the correct frontmatter (name, description):

1. infra-change — for any Terraform or Ansible change: fmt → validate → tflint/checkov if installed → plan -out → summarise adds/changes/destroys → STOP and hand the apply command to the human. Include what to do when a plan shows an unexpected destroy.
2. deploy-and-rollback — how a release is triggered and verified, how the automatic rollback works, and how to roll back manually from the instance via SSM if CI is down.
3. incident-drill — run one controlled failure, capture the symptom, diagnostic commands with their real output, root cause, fix and prevention, and write it up in docs/incidents/NNNN-<slug>.md.

Each skill needs: when to use it, prerequisites, steps, verification, failure handling, security constraints, and completion criteria. Keep each under ~80 lines. Do not create a SKILLS.md index. CLAUDE.md already lists them.
```

**Gate:** in a fresh session, ask "what skills do you have?" and confirm all three are listed.

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

For every IAM policy, explain each action and why it's needed. Run plan and stop.
```

**You run:** apply. Then `aws ssm describe-instance-information` and confirm the instance shows as Online.

**Gate:** you can open an SSM session to the instance, and port 22 is closed or limited to your IP.

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
```

**You run:** the playbook twice.

**Gate:** the second run reports `changed=0`, and `curl -I https://<domain>` returns the Nginx response with a valid cert.

---

## Phase 7 — Docker done properly

```
Containerise the application without changing its behaviour.

- multi-stage build; pinned base image; non-root user; HEALTHCHECK against the health endpoint; handles SIGTERM
- add a health endpoint only if the audit found none; add a test for it
- .dockerignore excludes .git, .env, tests artefacts, node_modules/.venv as appropriate
- config from env vars; secrets never baked into the image or build args

Build locally, run it, hit the health endpoint, run the existing tests, run `trivy image` and report HIGH/CRITICAL findings with a fix or a justified exception for each. Report the final image size.
```

**Gate:** the container starts, it is healthy, it runs as non-root (`docker exec <c> id`), and the Trivy results are documented.

---

## Phase 8 — CI/CD with OIDC and automatic rollback

```
Use the deploy-and-rollback skill.

Create GitHub Actions workflows (extend existing ones from the audit rather than duplicating them):
- ci.yml on PRs: lint, test, docker build, Trivy (fail on CRITICAL), terraform fmt/validate
- deploy.yml on main: same checks → build → push to ECR tagged with the full git SHA → deploy via aws ssm send-command
- pin every third-party action to a commit SHA; least-privilege `permissions:` block per job; id-token: write only on the job that assumes the AWS role

On-instance deploy script (installed by Ansible): pull the image by SHA; fetch secrets from Parameter Store into the container env without writing them to disk or logs; start the new container; poll its health for N seconds; on success, switch Nginx/upstream and record current/previous tags; on failure, keep or restore the previous container and exit non-zero so the workflow fails.

Before I merge, show the exact trust policy the workflow will assume. Explain how to test the rollback deliberately.
```

**Gate:** one green deploy, then a deliberately broken commit (a health endpoint returning 500) that the pipeline **rolls back automatically** while the site stays up. Save the run links.

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

Run one session per incident, using the incident-drill skill:

```
Use the incident-drill skill for: <disk full | app container stopped | 443 blocked in the security group | expired certificate>.
Tell me exactly what you'll do to cause the failure and how to undo it before doing anything. Wait for my OK.
For the security-group change, give me the command to run myself.
For the expired cert, don't try to make a real Let's Encrypt cert expire. Propose a safe simulation (e.g. a short-lived self-signed cert on a test subdomain) and say what it does and doesn't prove.
```

Then:

```
Write the README: what it is, the architecture diagram (from the .mmd), prerequisites, make up / make destroy (create the Makefile wrapping the existing commands; destroy must print the plan and require typed confirmation), cost note linking cost-estimate.md, and links to every docs/incidents/ write-up.
Finally, review the full diff since main for secrets, wildcard IAM, open ports and unpinned versions. List anything still unverified.
```

**Gate:** someone else could clone the repo, read the README, and understand both how it works and how it fails.
