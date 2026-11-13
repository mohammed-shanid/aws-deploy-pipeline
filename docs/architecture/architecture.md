# Architecture

Status: **design only**. Nothing below is deployed yet. Each component says which phase builds it.
Last reviewed: 2026-10-24.

Diagram: [`diagrams/architecture.mmd`](diagrams/architecture.mmd). Decisions: [`adr/`](adr/).
Related: [security](security.md) · [deployment](deployment.md) · [cost](cost-estimate.md).

## 1. What we are deploying (verified facts)

Checked on 2026-10-24 against branch `infra/demo-app` (commit `ab5e4ab`). Tests: `pytest` → **14 passed**; `ruff check .` → **All checks passed**.

| Fact | Value | Source |
|---|---|---|
| Runtime | Python 3.12.14, FastAPI 0.162.0, Uvicorn 0.54.0 | `.python-version`, `requirements.txt` |
| Start command | `python -m app` | `app/__main__.py` |
| Bind address | `HOST`/`PORT`, default `127.0.0.1:8000` | `app/__main__.py` |
| Endpoints | `GET /health` (200 `{"status":"ok"}` once started, 503 before), `GET /version` (`git_sha`, `started_at`), `GET /` | `app/main.py` |
| Config | `APP_ENV` (unset ⇒ `prod`), `GIT_SHA`, `DEMO_SECRET` | `app/config.py` |
| Secrets | `DEMO_SECRET`. Required unless `APP_ENV=dev`; the app exits with code 2 if it is missing | `app/config.py`, `app/__main__.py` |
| Shutdown | SIGTERM: stops accepting connections, waits up to 10 s for in-flight requests, exits 143 | `app/__main__.py` |
| Logging | One JSON line per event to stdout, with an allowlist of extra fields (no headers, query strings or bodies) | `app/logging_setup.py` |
| State | None. No database, no files written, no external calls | whole package |
| Dependencies | All runtime and dev packages pinned to exact versions (not hash-pinned) | `requirements*.txt` |

The app is a **stateless HTTP service** with a real health endpoint, so the Nginx + TLS + HTTPS-uptime design in CLAUDE.md applies. The worker redesign (PROMPTS.md, after Phase 1) is not needed.

Two facts that shape the infrastructure:

- **The default bind of `127.0.0.1` does not work inside a container**: a port published from the host cannot reach it. The container must set `HOST=0.0.0.0`, and the host publishes it on loopback only (`-p 127.0.0.1:<slot port>:8000`). So "app on 127.0.0.1" in CLAUDE.md is a fact about the **host** side.
- **Statelessness makes the instance disposable.** If the host is lost, recovery is to rebuild it (Terraform → Ansible → deploy the last good SHA). Nothing needs restoring from backup.

## 2. Components

| # | Component | Purpose | Phase |
|---|---|---|---|
| 1 | **Bootstrap**: S3 state bucket and AWS Budget alert | Remote state with native locking; a cost tripwire | 4 |
| 2 | **VPC**: 1 public subnet, IGW, route table | Network for one instance. **No private subnets** (see §5) | 5 |
| 3 | **Security group** | Ingress 80/443 from `0.0.0.0/0` (and `::/0` if IPv6 is enabled). 22 closed by default | 5 |
| 4 | **EC2** (Ubuntu LTS, IMDSv2 only, hop limit 1, encrypted gp3 root) + **Elastic IP** | Runs Nginx, Docker, SSM agent and CloudWatch agent | 5 |
| 5 | **Instance role** | SSM core, ECR pull (this repo only), CloudWatch agent, read `/<project>/<env>/*` parameters | 5 |
| 6 | **ECR repository** | Immutable tags, scan on push, lifecycle policy keeping the last N images | 5 |
| 7 | **GitHub OIDC provider + deploy role** | CI gets short-lived credentials. Trust limited to `repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main` | 5 |
| 8 | **SSM Command document `<project>-deploy`** | The only thing CI may run on the host: the deploy script, with a SHA parameter validated by regex (see ADR 0002) | 5/8 |
| 9 | **Host config (Ansible)**: deploy user, ufw, unattended upgrades, Docker, Nginx, certbot, logrotate | Repeatable host build | 6 |
| 10 | **Container image** | Multi-stage, pinned base, non-root, `HEALTHCHECK` | 7 |
| 11 | **GitHub Actions**: `ci.yml` (PRs), `deploy.yml` (main) | Lint, test, build, Trivy, push, deploy | 8 |
| 12 | **On-host deploy script** | Two-slot release with health gate, automatic rollback, records current/previous tags | 8 |
| 13 | **CloudWatch**: agent metrics, log groups with retention, alarms → SNS email, HTTPS uptime and cert-expiry checks | Detection | 9 |
| 14 | **SSM Parameter Store** (SecureString) `/<project>/<env>/DEMO_SECRET` | App secret. Created by the human, **not** by Terraform (ADR 0005) | 5 (IAM) / human |

## 3. Data flows

**User request.**
Browser → DNS (A record → Elastic IP) → SG (443) → ufw → Nginx (TLS termination, security headers) → `127.0.0.1:<active slot port>` → container `:8000` → FastAPI.
Port 80 serves only the ACME HTTP-01 challenge and a redirect to HTTPS.

**Release** (detail in [deployment.md](deployment.md)).
Push to `main` → Actions runs lint, test, build and Trivy → assumes the deploy role via OIDC → pushes `ECR:<full git SHA>` → `ssm:SendCommand` with the `<project>-deploy` document and `sha=<SHA>` → the SSM agent runs the deploy script on the host → the script pulls the image (using the instance role), reads `DEMO_SECRET` from Parameter Store, starts the inactive slot, polls `/health`, switches Nginx and records the tags → the workflow waits for the command result and fails if the result is non-zero.

**Operations.**
Operator → AWS SSO/CLI profile → SSM Session Manager (shell) or `send-command`. No inbound SSH in normal operation.
SSM agent, CloudWatch agent and Docker all connect **outbound** over 443 through the IGW to SSM, EC2 Messages, ECR, S3 (image layers), CloudWatch and Logs endpoints.

**Telemetry.**
CloudWatch agent → metrics (mem, disk) and logs (container JSON logs, Nginx access/error) → alarms → SNS → email.

## 4. Trust boundaries

| Boundary | Crossing | Control |
|---|---|---|
| Internet → host | TCP 80/443 | SG + ufw. TLS at Nginx. App reachable only on loopback |
| Nginx → app container | HTTP on loopback | Not encrypted, and does not need to be: same host, loopback interface |
| Container → host / AWS | Container process | Non-root user. IMDS hop limit 1, so the container **cannot** use the instance role. No Docker socket mounted |
| GitHub → AWS | OIDC token → STS | Trust policy pins `aud=sts.amazonaws.com` and `sub` to repo + `main`. Role can only push to one ECR repo and run one SSM document on one instance |
| AWS control plane → host | SSM agent (outbound session) | Whoever holds `ssm:SendCommand`/`StartSession` on the instance is effectively root. So that permission is scoped tightly (security.md) |
| Host → AWS APIs | Instance role via IMDSv2 | Least-privilege role. Secrets readable only under `/<project>/<env>/*` |
| Operator → AWS | Human credentials | Out of scope for IaC. MFA expected. No long-lived keys anywhere (hard rule 2) |

## 5. Decisions challenged during design

Each item records the instruction or assumption, what the audit found, and the conclusion.

1. **Private subnets: drop them.** Nothing runs in them. There is no RDS, no NAT, and nothing that needs to be unreachable from the IGW. Empty private subnets cost $0, but they add Terraform code, route tables and a false sense of isolation, and they invite someone to put a NAT Gateway behind them later (~$33/month plus data, see cost-estimate.md). Add them in the same change that introduces something that needs them (for example RDS, which needs a DB subnet group across two AZs). Phase 5 should create **one public subnet only**.
2. **Terraform ≥ 1.10 is not enough for `use_lockfile`.** In 1.10, S3 lockfile locking was *experimental*. From 1.11 it is no longer marked experimental, and DynamoDB locking is deprecated. Require **`>= 1.11`** (ADR 0004). CLAUDE.md should be updated to match; that change is proposed, not made.
3. **`ssm:SendCommand` on `AWS-RunShellScript` would make the CI role root on the host.** That is broader than "deploy". Use a custom Command document with one regex-validated parameter instead (ADR 0002).
4. **Close port 22 entirely** rather than opening it to an operator /32. Session Manager covers shell access. Ansible can use the SSM connection plugin (feasibility to confirm in Phase 6). Break-glass SSH is a temporary, human-applied rule (deployment.md §5).
5. **Instance size: `t3.small` (2 GiB), not `t3.micro`.** Docker, Nginx, the SSM agent, the CloudWatch agent and two app containers during a switch will press on 1 GiB of RAM. Graviton `t4g.small` is cheaper but needs arm64 images, so CI would need an arm64 runner or a QEMU cross-build. Start on x86 `t3.small`. Revisit if cost matters more than build simplicity. (Estimate: ~$15/month in us-east-1. See cost-estimate.md.)
6. **Do not manage the secret's value in Terraform.** A value Terraform manages, or even reads, ends up in state. The human creates the parameter with the CLI; Terraform grants read access only (ADR 0005).

## 6. Assumptions (need human confirmation)

- **AWS region**: not decided. Costs are estimated for `us-east-1` and `ap-south-1`.
- **Domain**: the operator owns one and controls its DNS. The A record change is a human action (hard rule 1). Whether DNS is Route 53 or external is unknown.
- **Single environment** `dev` for now. Names use `/<project>/<env>/`.
- **GitHub repo** `mohammed-shanid/aws-deploy-pipeline` (from `git remote`). Deploys come only from `main`.
- **Branch protection on `main`** (required PR review and status checks) will be enabled by the human. Without it, anyone with write access can deploy by pushing to `main`, and the OIDC trust condition is only as strong as that.
- **Operator access** to AWS uses SSO or short-lived credentials. No AWS credentials were configured in this shell on 2026-10-24, and Terraform is not installed locally. Both block Phase 4.
- **Downtime tolerance**: minutes of downtime on instance failure are acceptable (single instance, no ALB).

## 7. Trade-offs accepted

| We accept | In exchange for | Revisit when |
|---|---|---|
| A single point of failure. Instance or AZ loss means downtime until rebuild (estimate: 15–30 min manual) | An estimated ~$21/month total (cost-estimate.md), and a system one person can understand | An uptime SLO is stated, or there is paying traffic |
| TLS terminated on the instance (certbot) instead of ACM + ALB | No ALB (~$16+/month); ACM certs cannot be installed on EC2 directly | We add a second instance |
| Two-slot switch on one host instead of rolling across hosts | Zero-downtime deploy without a load balancer | Same as above |
| Mutable host configured by Ansible instead of baked AMIs | Simpler pipeline. Ansible idempotency is checked (`changed=0`) | Configuration drift causes an incident |
| Basic CloudWatch alarms and email | Low cost, no extra tooling | We need paging or on-call |
