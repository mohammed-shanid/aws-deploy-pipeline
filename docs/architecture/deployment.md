# Deployment and rollback

Status: **the on-host part exists and is tested locally; nothing is on AWS.** The deploy script, the watchdog and the Dockerfile are implemented and pass the local harness (§6.4, 2026-11-13). The workflows and the SSM document do not exist yet, and the `ecr` and `ssm` branches of the deploy script have never run. Paths and names below are the contract; a change to them must update this file. Last reviewed: 2026-11-13.

## 1. Release identity

- Release tag = **full 40-char git SHA**. ECR tags are immutable, so a tag can never point to different bits.
- The container receives `GIT_SHA=<sha>`, and `GET /version` returns it. That is how we verify what is live.
- `latest` and other mutable tags are never pushed or pulled.

## 2. Release flow

```
PR ─▶ ci.yml: ruff, pytest, docker build, Trivy (fail on CRITICAL), terraform fmt/validate   [no AWS creds]
merge to main ─▶ deploy.yml:
   1. same checks
   2. build image, tag <sha>
   3. assume deploy role (OIDC)
   4. push ECR:<sha>
   5. aws ssm send-command --document-name <project>-deploy --instance-ids <id> --parameters sha=<sha>
   6. wait for the command; fetch stdout/stderr (Run Command output via API is truncated, so also send it to CloudWatch Logs)
   7. curl https://<domain>/version and assert git_sha == <sha>
   8. exit non-zero on any failure ⇒ red pipeline
```

### On-host deploy script (`/opt/app/bin/deploy <sha>`)

Two **slots** on loopback: A = `127.0.0.1:8001`, B = `127.0.0.1:8002`. Nginx proxies to the active slot through `/etc/nginx/app-upstream.conf`.

Inputs come from `/etc/app/deploy.env`, written by Ansible:

| Variable | AWS | Local harness | Why it differs |
|---|---|---|---|
| `IMAGE_REPO` | `<acct>.dkr.ecr.<region>.amazonaws.com/<repo>` | `127.0.0.1:5000/aws-deploy-pipeline` | No ECR locally; a registry container on the machine's loopback |
| `REGISTRY_AUTH` | `ecr` | `none` | ECR login needs the instance role |
| `SECRETS_SOURCE` | `ssm` | `none` | No Parameter Store locally. The app runs with `APP_ENV=dev`, where `DEMO_SECRET` is optional |
| `APP_ENV` | `dev` (the AWS environment name) | `dev` | |
| `HEALTH_TIMEOUT_SECONDS` | `60` | `60`; the rollback test overrides it to 20 via the environment | Shorter test runs |
| `SECRET_PARAMETER` | `/<project>/<env>/DEMO_SECRET` | empty | Only read when `SECRETS_SOURCE=ssm` |
| `APP_DOMAIN` | the real domain | `app.adp.test` | After the switch the script requests `/version` through Nginx under this name |
| `TLS_CA_FILE` | empty (system trust store; Let's Encrypt) | `/etc/ssl/adp/app.crt` | The self-signed certificate is trusted explicitly; verification is never turned off |

The file is parsed as `KEY=VALUE` data, not executed, and a value already in the environment wins.

Everything else, including the health gate, the slot switch and the state files, is the same code on both, which is what makes the local rollback test meaningful.

1. `flock` on `/opt/app/deploy.lock`, so concurrent deploys fail fast.
2. Validate `sha` against `^[0-9a-f]{40}$`. The SSM document validates it too; this is a second check.
3. `docker pull <ecr>/<repo>:<sha>`.
4. Read `DEMO_SECRET` from Parameter Store into a shell variable (security.md §4).
5. Start the container in the **inactive** slot (containers are named `adp-app-a` / `adp-app-b`; a leftover container in that slot is removed first): `-p 127.0.0.1:<slot port>:8000`, `-e HOST=0.0.0.0 -e APP_ENV -e GIT_SHA -e DEMO_SECRET`, `--stop-timeout 15` (longer than the app's 10 s graceful window), `--restart unless-stopped`, `--label adp.app=aws-deploy-pipeline` (how tests and operators find app containers), log rotation options, and hardening: `--read-only --tmpfs /tmp --cap-drop ALL --security-opt no-new-privileges --memory 384m --pids-limit 256`.
6. Poll `http://127.0.0.1:<slot port>/health` until it returns 200, for up to N s (default 60). The app returns 503 until its startup has completed, so a 200 means it is ready. If the container exits or Docker restarts it, the script stops waiting at once.
7. **Success**: rewrite the upstream file → `nginx -t` → `systemctl reload nginx` → wait up to 15 s until `/version` **through Nginx** (TLS verified) returns the new SHA → write state → `docker stop` and remove the old slot (SIGTERM, which drains requests) → delete images of this repo other than current and previous.
8. **Failure** at any step: remove the new container, leave the old slot serving untouched, and exit non-zero. If the failure happened *after* the Nginx switch, restore the previous upstream file and reload first.

State: `/opt/app/state/current` and `/opt/app/state/previous`. Each is written atomically (temp file, then `mv`). The first line is the SHA; later lines may hold the slot and timestamp:

```
<sha>
slot=<A|B> deployed_at=<ts>
```

A failed deploy changes neither file. The local rollback test asserts this.

Because the state lives on the host, rollback never depends on CI. Redeploying the SHA that is already current leaves `previous` alone.

### Watchdog (`/opt/app/bin/watchdog`)

A crash is handled by `--restart unless-stopped`. A **hang** is not: the process is up and the port is open, but nothing answers. The image's `HEALTHCHECK` (every 10 s, 3 failures) makes Docker mark such a container `unhealthy`, but Docker never restarts it. `adp-watchdog.timer` runs the watchdog every 30 s; it restarts any app container that is `unhealthy`. It takes the deploy lock without waiting and does nothing while a deploy is running, so it cannot interfere with a release that is still starting. Measured locally with the app process frozen by `SIGSTOP`: unhealthy after 36 s, serving again after 57 s (that includes the 15 s stop timeout). Requests fail during that window; one instance has nothing to fail over to (ADR 0001).

## 3. Automatic rollback

Strictly speaking, nothing is rolled *back*. The new release never receives traffic until its health check passes. Failure modes covered:

| Failure | Result |
|---|---|
| Image pull fails | Old slot keeps serving. Pipeline red |
| Container exits on start (e.g. missing `DEMO_SECRET` ⇒ exit 2) | Health poll times out. New container removed. Pipeline red |
| `/health` returns non-200 | Same as above |
| Nginx config test fails after the switch | Previous upstream restored and reloaded. Pipeline red |
| Bug that passes `/health` but breaks pages | **Not covered.** Needs a manual rollback (§4). Smoke tests in step 7 can widen coverage later |

Rollback tests: locally first, `infra/ansible/tests/deploy_rollback.sh` (§6) runs this scenario on every change to the deploy script. Then the Phase 8 gate on AWS: commit a change that makes `/health` return 500, merge, then confirm (a) the pipeline goes red, (b) `curl https://<domain>/version` still shows the previous SHA throughout, (c) `/opt/app/state/current` and `previous` are unchanged.

## 4. Manual rollback

When to use: a bad release passed the health check, or CI/GitHub is unavailable.

From the operator's terminal (no CI needed):

```bash
aws ssm start-session --target <instance-id>
sudo cat /opt/app/state/previous           # find previous SHA
sudo /opt/app/bin/deploy <previous-sha>   # same health-gated path as a normal deploy
curl -s https://<domain>/version           # confirm
```

Or without an interactive shell:
`aws ssm send-command --document-name <project>-deploy --instance-ids <id> --parameters sha=<previous-sha>`.

Rolling back to any older SHA works the same way, as long as the image is still in ECR (the lifecycle policy keeps the last N images; choose N ≥ 10).

## 5. Break-glass

Use these in order. Each step is run by the human.

1. **Session Manager works, but the app or Nginx is broken.** Shell in with `aws ssm start-session`, then use `docker ps -a`, `docker logs`, `journalctl -u nginx`, `nginx -t`.
2. **SSM agent offline, instance running** (check `aws ssm describe-instance-information` and the EC2 status checks):
   - Reboot: `aws ec2 reboot-instances --instance-ids <id>`.
   - Still offline: temporarily allow `22/tcp` from your current /32 (human SG change, then revert), and connect with **EC2 Instance Connect** (`aws ec2-instance-connect ssh --instance-id <id>`). This pushes a 60-second key, so no long-lived key pair is needed. Requires the `ec2-instance-connect` package (present on Ubuntu AMIs; confirm in Phase 5). **Remove the rule afterwards.**
3. **Instance unrecoverable.** The app is stateless, so rebuild it: `terraform plan -replace=aws_instance.<name>` → human applies → Ansible playbook → `deploy <last good sha>`. The Elastic IP is reassociated by Terraform, so DNS does not change. Estimated time: 15–30 min (unmeasured; measure in Phase 10).
4. **Pipeline itself compromised.** Remove the trust by deleting the OIDC provider or role, or set the role's trust to deny (human IAM action). Then investigate.

Every use of break-glass gets an incident write-up in `docs/incidents/`.

## 6. Local test harness

Each phase runs these checks before anything touches AWS. None of them needs AWS credentials. An AWS run costs money and is slow to iterate on, and some mistakes there, such as a bad sshd config or an open port, are risky. Locally, the same mistakes cost seconds.

Prerequisites: Terraform ≥ 1.7 for mocking (CI pins 1.16.7); `python3.12 -m venv .venv-infra && .venv-infra/bin/pip install -r requirements-infra.txt` (checkov, ansible-core, ansible-lint); `.venv-infra/bin/ansible-galaxy collection install -r infra/ansible/collections/requirements.yml -p .ansible/collections` (pinned `community.general` and `community.crypto`); [OrbStack](https://orbstack.dev) (`orb`) for the Ansible and deploy tests.

### 6.1 What runs locally

| Check | Command | Where | What it proves |
|---|---|---|---|
| Terraform guardrails | `terraform -chdir=infra/terraform/envs/dev init -backend=false` then `… test` | Local + CI (`ci.yml`) | With the AWS provider mocked: required tags set in `local.common_tags` → `default_tags`, and no resource overrides them; no ingress on 22 by default, and `operator_cidr` rejects anything but a /32; public ingress is 80/443 only; IMDSv2 required with hop limit 1; root and attached EBS volumes encrypted; OIDC provider is GitHub with audience `sts.amazonaws.com`; trust policy is one statement with `StringEquals` on `sub = repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main` |
| checkov | `.venv-infra/bin/checkov` (reads `.checkov.yaml`) | Local + CI | Built-in AWS misconfiguration rules, plus `CKV_ADP_1`: every `aws` provider block, aliases included, sets the four required tags via `default_tags` |
| Mutation check (tests the tests) | `.venv/bin/python infra/tests/terraform_mutation/mutate.py` (~3 min) | Local | The guardrail tests and `CKV_ADP_1` pass on a minimal fixture that meets the contract, and each of 18 single-rule violations fails **exactly the run named for it** (4 more for `CKV_ADP_1`). The fixture lives outside `infra/terraform` so the real-infra checkov scan does not pick it up |
| Ansible idempotence | `infra/ansible/tests/idempotence.sh [--fresh] [--role NAME]` | Local (OrbStack Ubuntu 24.04) | Every role converges on a clean Ubuntu 24.04 host, and a second run reports `changed=0`. A failure names the role and task |
| Deploy / rollback | `infra/ansible/tests/deploy_rollback.sh` | Local (OrbStack) | A good release (tagged with HEAD's SHA) deploys and serves `/version` through Nginx/TLS. Two broken releases (`/health` → 500; crash on start) each make the deploy exit non-zero, while the **same container** keeps serving the good SHA with zero failed requests during the deploy, `state/current` and `state/previous` stay unchanged, and no broken container is left behind |

TLS: locally Nginx uses a self-signed certificate (`tls_mode: selfsigned`, cert at `/etc/ssl/adp/app.crt` with `app.adp.test` as a SAN). The rollback test trusts that exact file with `--cacert` rather than turning verification off. Let's Encrypt (`tls_mode: letsencrypt`) is AWS-only: a `.test` name cannot pass an ACME challenge, and test runs must not spend Let's Encrypt rate limits.

The tests are the spec for Phases 5–8. A phase must not edit them to get to green (CLAUDE.md rule 8). The Terraform test header lists the resource addresses the dev env must use.

### 6.2 What only runs on AWS, and why

| Check | Why not locally | When |
|---|---|---|
| Real `terraform plan` | Needs credentials. Data sources (AMI, AZs) need the API, and mocks return random computed values (strings are random 8-char, collections empty) | Phase 5, human's `AWS_PROFILE` |
| `tags_all` on **every** resource | Computed by the real provider from `default_tags`. checkov does not merge `default_tags` into resources, so locally only the provider block is checked | Phase 5, on the saved plan (command below) |
| IAM evaluation: does a role actually allow or deny, and does STS accept a real GitHub token | Mocks check the policy JSON text, not how AWS evaluates it | Phase 5 (Access Analyzer `validate-policy` is read-only and optional), Phase 8 first OIDC deploy |
| SSM agent, Session Manager, the deploy Command document, Ansible over SSM | No SSM endpoint locally. Locally Ansible connects through OrbStack's SSH | Phase 5 gate, Phase 6 |
| ECR login and pull with the instance role (`REGISTRY_AUTH=ecr`) | No ECR or IMDS locally | Phase 8 first deploy |
| Secret fetch from Parameter Store (`SECRETS_SOURCE=ssm`) | No Parameter Store locally; the local app runs with `APP_ENV=dev` | Phase 8 first deploy |
| IMDS hop limit blocking containers | No IMDS locally. Terraform test only checks the setting | Phase 8: from a container, a request to `169.254.169.254` must fail |
| Let's Encrypt issuance and the renewal timer | Needs public DNS and inbound 80 | Phase 6 on AWS, `certbot renew --dry-run` |
| Security group and ufw as seen from the internet | OrbStack's network is not the VPC, and ufw inside an OrbStack machine (shared kernel) may not behave like on EC2 | Phase 5/6 gate: probe 22/80/443 from outside |
| sshd hardening does not lock you out | OrbStack's SSH server is not the machine's sshd, so a local run cannot prove you can still log in | Phase 6 on AWS, with an SSM session kept open |
| CloudWatch agent, alarms, SNS | AWS services | Phase 9 |
| GitHub Actions → OIDC → STS → SSM end to end | Needs GitHub and AWS | Phase 8 gate |

Tag check on the real plan (prints any resource missing a required tag; empty output means pass):

```bash
terraform -chdir=infra/terraform/envs/dev show -json tfplan | jq -r '
  .resource_changes[]
  | select(.change.after | type == "object" and has("tags_all"))
  | select((.change.after.tags_all // {}) as $t
      | ["Project","Environment","Owner","ManagedBy"] | all(. as $k | $t | has($k)) | not)
  | .address'
```

### 6.3 Local and AWS differences that can hide bugs

- The OrbStack `ubuntu:noble` image is not Canonical's EC2 AMI. Package sets differ, and there is no cloud-init unless asked for. Roles must install what they use rather than assume it is preinstalled.
- OrbStack machines share a kernel and are not full VMs, so kernel modules, sysctl and firewall behaviour can differ.
- CPU architecture matches `t3.small` (x86_64) only on an Intel Mac. On Apple Silicon the machine is arm64, so an image that works locally proves nothing about amd64.

### 6.4 Harness verification record

| Date | What | Result |
|---|---|---|
| 2026-10-24 | Terraform tests against a scratch config that meets the contract (not committed), Terraform 1.16.7 | **Tested and passed**: 6/6 runs |
| 2026-10-24 | Same tests against 18 single-violation variants (missing tag, tag overridden, 22 open in four ways, missing /32 validation, IMDSv1, IMDS block missing, hop limit 2, unencrypted root, missing root block, unencrypted extra EBS, `StringLike` wildcard sub, other repo, other branch, missing `aud`, wrong OIDC URL) | **Overstated, superseded by the next row**: the script only checked for a non-zero exit. The "missing /32 validation" variant (`condition = true`) was rejected by Terraform as invalid config, not caught by a test |
| 2026-10-24 | `CKV_ADP_1` against the good config plus 4 violations (no `default_tags`, missing Owner, wrong ManagedBy, untagged aliased provider) | **Tested and passed** |
| 2026-10-24 | Both checks above, re-run with the committed `infra/tests/terraform_mutation/mutate.py`: fixture and lock file committed, and each variant must fail exactly its expected run. The /32 variant is now a realistic weakening (any CIDR accepted) | **Tested and passed**: baseline 6/6; 18/18 Terraform and 4/4 `CKV_ADP_1` mutations caught as expected. The first run of the stricter script reported the /32 variant `MISSED` and exited 1, which is how the overstated row above was found |
| 2026-10-24 | Idempotence callback and checker against toy roles on localhost | **Tested and passed**: fails on run 1, passes on an idempotent run 2, names the role of a non-idempotent task |
| 2026-10-24 | Broken-release fixture (`broken_app.py`) on the Mac | **Tested and passed**: `/health` 500, `/version` 200; crash mode exits 3 |
| 2026-10-24 | `orb_machine.sh`, `idempotence.sh`, `deploy_rollback.sh` end to end | **Blocked**: OrbStack is not installed, and nothing to run yet (roles: Phase 6, Dockerfile: Phase 7, deploy script: Phase 8). `bash -n` and shellcheck 0.11.0 clean |
| 2026-11-13 | `orb_machine.sh` first real run (OrbStack now installed, Intel Mac so the machine is x86_64 like `t3.small`) | **Bug found and fixed**: `machine_exists` skipped the first line of `orb list` as a header, but piped `orb list` prints none, so the existing machine was not detected and `--fresh` failed with "machine already exists" |
| 2026-11-13 | `idempotence.sh --fresh` on `site.yml` (roles `base`, `ssh`, `firewall`, `docker`, `nginx`, `app_deploy`) | **Tested and passed**: run 1 `ok=50 changed=35 failed=0`, run 2 `ok=46 changed=0`. Found on the way: on a clean 24.04 host `sshd -t` fails ("Missing privilege separation directory: /run/sshd") until the socket-activated `ssh` service has started once; the role now starts it before validating |
| 2026-11-13 | `idempotence.sh --role <name>` for all six roles | **Tested and passed**: second run `changed=0` for each. Run on the machine `site.yml` had already configured, so this does **not** prove each role converges alone from a clean host |
| 2026-11-13 | `ansible-lint` (production profile, `.ansible-lint`); `site.yml --check --diff` on the configured machine | **Tested and passed**: 0 failures, 0 warnings; check mode `changed=0` with no diff |
| 2026-11-13 | State of the machine after the run, checked by hand | **Tested and passed**: `sshd -T` shows `permitrootlogin no`, `passwordauthentication no`, `kbdinteractiveauthentication no`; `ufw status` default deny incoming with only 80/tcp and 443/tcp allowed; from the Mac to the machine's IP, 22 and 8001 are unreachable and 80/443 open (so ufw does filter in an OrbStack machine); Docker 29.9.3 from Docker's repo, `json-file` logs capped at 10m × 5, the `deploy` user (locked password) can run `docker ps`; certificate `CN=app.adp.test` with SAN `DNS:app.adp.test`, key mode 0600; `/etc/app/deploy.env` holds the five variables from §2 |
| 2026-11-13 | Nginx behaviour, `curl` inside the machine with `--cacert /etc/ssl/adp/app.crt` (verification on) | **Tested and passed**: port 80 returns 301 to `https://app.adp.test/...` even with `Host: evil.example`; 443 returns 502 with no app running, carrying HSTS, `nosniff`, `X-Frame-Options: DENY`, `Referrer-Policy` and CSP headers; 200 through a throwaway `python3 -m http.server` on `127.0.0.1:8001`; a request for another hostname fails certificate verification; TLS 1.1 is refused |
| 2026-11-13 | `tls_mode: letsencrypt`, the AWS inventory, Ansible over SSM | **Not implemented**: the nginx role fails on purpose if `letsencrypt` is requested (always when `env_name` is `local`). Roadmap Day 5 |
| 2026-11-13 | Dockerfile: build, run with `APP_ENV=dev`, on the Mac (Docker 29.8.2, amd64) | **Tested and passed**: `/health` 200, `/version` returns the `GIT_SHA` passed in, `id` is uid 10001, Docker health `healthy`, `docker stop` returns in 0.5 s with "Application shutdown complete" in the log; without `APP_ENV` it exits 2 (fails closed). App tests before and after: 14 passed; `ruff check .` clean |
| 2026-11-13 | Trivy 0.76.2 on the image | **Tested**: 0 CRITICAL, 47 HIGH (11 CVEs, none with a Debian fix). Each is written up with a dated exception in [security.md §6](security.md#6-image-scan-results) |
| 2026-11-13 | `idempotence.sh --fresh` with the deploy script, watchdog and units added to `app_deploy`; shellcheck 0.11.0 on both scripts; `ansible-lint` | **Tested and passed**: run 1 `changed=38`, run 2 `changed=0`; shellcheck and lint clean |
| 2026-11-13 | `deploy_rollback.sh` (image built inside the machine from the working tree, tagged with HEAD `9072a5a`; fixtures built on top of it) | **Tested and passed**, unedited: good release deployed and served through Nginx/TLS; `health500` deploy exited 1 after the 20 s gate with 89/89 requests still served by the good release; `crash` deploy exited 1 after 2 s (restart loop detected) with 8/8; state files unchanged, no broken container left |
| 2026-11-13 | Beyond the harness, run by hand in the machine | **Tested and passed**: a second good release switched B → A while 50 requests were in flight, 0 failed (24 old SHA, 26 new); `current`/`previous` recorded; manual rollback with `deploy $(head -n1 state/previous)` worked; a non-SHA argument and a second concurrent deploy were both refused with exit 1; the container runs as uid 10001 with a read-only root and all capabilities dropped; after the deploys a playbook run still reports `changed=0` and does not reset the upstream file |
| 2026-11-13 | Watchdog, app process frozen with `SIGSTOP` | **Tested and passed**: Nginx stopped getting answers, Docker reported `unhealthy` after 36 s, the watchdog restarted the container and `/health` was 200 again after 57 s. One run, not repeated |
| 2026-11-13 | Deploy script with `REGISTRY_AUTH=ecr` and `SECRETS_SOURCE=ssm`; the AWS CLI on the host | **Implemented, not tested**: no ECR or Parameter Store locally (§6.2). Nothing installs the AWS CLI on the host yet. First real run is the first AWS deploy |
| 2026-10-24 | `ci.yml` `iac` job | **Implemented, not run on GitHub**. Its Terraform step was run locally under bash: warns and skips while `envs/dev` has no `*.tf`, and runs validate + test once it does |
