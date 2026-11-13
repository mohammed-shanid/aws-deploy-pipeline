# Security design

Status: **design only**. Nothing here is deployed or verified against AWS yet. Last reviewed: 2026-10-24.
Hard rules referenced (R1–R9) are in [CLAUDE.md](../../CLAUDE.md).

## 1. Threats and controls

| # | Threat | Likelihood / impact | Control (phase) |
|---|---|---|---|
| T1 | Someone with repo write access deploys malicious code by pushing to `main` | Med / High | Branch protection on `main` with required review and checks (**human action**). OIDC trust is pinned to `ref:refs/heads/main` (5). PR workflows never receive AWS credentials (8) |
| T2 | A compromised or retagged third-party GitHub Action steals the OIDC token | Low / High | Every action pinned to a commit SHA. `id-token: write` only on the job that assumes the role (8) |
| T3 | The CI role is abused to run arbitrary commands on the host | Med / High | `ssm:SendCommand` scoped to **one instance ARN and one custom Command document**, whose only parameter is a 40-hex SHA (`allowedPattern`). Not `AWS-RunShellScript` (5, ADR 0002) |
| T4 | An app RCE turns into AWS access | Low / High | Container runs non-root, no Docker socket, IMDSv2 with **hop limit 1**, so the container cannot reach instance credentials (5, 7) |
| T5 | Secret leaks through logs, image, state or git | Med / High | Secret is read at container start, never baked into the image or build args (7). App logs use an allowlist and `Settings` has `repr=False` (verified in code). Value never in Terraform (ADR 0005). `.env` gitignored (verified) |
| T6 | Network exposure | Med / Med | SG: 80/443 only. 22 closed (R5). ufw mirrors the SG. App published on `127.0.0.1` only (5, 6) |
| T7 | Vulnerable dependency or base image | High / Med | Pinned base image by digest. Trivy fails CI on CRITICAL (8). ECR scan on push (5). Unattended security upgrades on host (6) |
| T8 | TLS certificate expires unnoticed | Med / High | certbot renewal timer (6), plus our own expiry alarm at < 14 days (9). Let's Encrypt is reported to have stopped expiry emails; verify in Phase 6 |
| T9 | Terraform state tampering or disclosure | Low / High | Private bucket with public access block, TLS-only policy, versioning, SSE. No secret values in state (4) |
| T10 | Runaway cost (e.g. someone adds a NAT Gateway, or abuse traffic) | Med / Med | AWS Budget email alert (4). R7 requires an ADR before any managed service is added |
| T11 | Lockout: a bad sshd or ufw change, or a dead SSM agent | Med / Med | 22 closed, so sshd mistakes don't lock us out of SSM. Ansible validates sshd config before reload (6). Break-glass procedure in [deployment.md §5](deployment.md#5-break-glass) |

## 2. IAM design

Permissions are listed per action, with why each one is needed. Every `"Resource": "*"` below is on an action that **does not support resource-level permissions**. Each one is a documented exception under R4. Exact ARNs are filled in during Phase 5.

### 2.1 Instance role (`<project>-<env>-instance`)

| Action | Resource | Why |
|---|---|---|
| Managed `AmazonSSMManagedInstanceCore` | AWS-defined | SSM agent registration, Run Command and Session Manager. AWS-managed. Contains `*` resources for `ssmmessages`/`ec2messages`, which the service requires |
| `ecr:GetAuthorizationToken` | `*` (R4 exception: not resource-scoped) | Get the registry login token |
| `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`, `ecr:BatchCheckLayerAvailability` | this repo's ARN | Pull images |
| `ssm:GetParameter` | `arn:aws:ssm:<region>:<acct>:parameter/<project>/<env>/*` | Read `DEMO_SECRET` at container start |
| `kms:Decrypt` | *probably not needed*. The AWS-managed `aws/ssm` key policy allows use via SSM for account principals | Decrypt SecureString. **Verify in Phase 5**, and add it scoped to the key with a `kms:ViaService` condition only if required |
| `cloudwatch:PutMetricData` | `*` (R4 exception), with condition `cloudwatch:namespace = CWAgent` | Agent metrics (mem, disk) |
| `logs:CreateLogStream`, `logs:PutLogEvents`, `logs:DescribeLogStreams` | this project's log group ARNs | Ship container and Nginx logs. Log groups are created by Terraform, so the agent needs no `CreateLogGroup` |

Prefer this custom CloudWatch policy over the managed `CloudWatchAgentServerPolicy`, which grants `logs:*`-style writes on `*`.

### 2.2 CI deploy role (`<project>-<env>-gha-deploy`)

Trust policy (shape; exact text is shown to the human before Phase 8 merges):

```json
{
  "Effect": "Allow",
  "Principal": { "Federated": "arn:aws:iam::<acct>:oidc-provider/token.actions.githubusercontent.com" },
  "Action": "sts:AssumeRoleWithWebIdentity",
  "Condition": {
    "StringEquals": {
      "token.actions.githubusercontent.com:aud": "sts.amazonaws.com",
      "token.actions.githubusercontent.com:sub": "repo:mohammed-shanid/aws-deploy-pipeline:ref:refs/heads/main"
    }
  }
}
```

`StringEquals`, not `StringLike` with wildcards. If the deploy job later uses a GitHub `environment:`, the `sub` changes to `repo:…:environment:<name>`, and the trust policy must change in the same PR.

| Action | Resource | Why |
|---|---|---|
| `ecr:GetAuthorizationToken` | `*` (R4 exception) | Registry login |
| `ecr:BatchCheckLayerAvailability`, `ecr:InitiateLayerUpload`, `ecr:UploadLayerPart`, `ecr:CompleteLayerUpload`, `ecr:PutImage` | this repo's ARN | Push the image |
| `ssm:SendCommand` | this instance's ARN **and** `<project>-deploy` document ARN | Trigger the deploy and nothing else |
| `ssm:GetCommandInvocation`, `ssm:ListCommandInvocations` | `*` (R4 exception; read-only, no resource-level support) | Wait for and read the deploy result |

No `ecr:BatchDeleteImage` (the lifecycle policy handles cleanup). No IAM permissions. No `ec2:*`.

### 2.3 Human operator

Out of IaC scope. Use SSO or short-lived credentials with MFA. Terraform apply, IAM and DNS changes are run by the human only (R1). This is also enforced locally by `.claude/settings.json`.

## 3. Network exposure

| Port | Source | Purpose |
|---|---|---|
| 443/tcp | `0.0.0.0/0` (+ `::/0` if IPv6 is enabled) | HTTPS |
| 80/tcp | `0.0.0.0/0` (+ `::/0`) | ACME HTTP-01 and redirect to 443 only |
| 22/tcp | **closed** by default (`var.operator_cidr = null`) | Break-glass only, human-applied, a single /32, removed afterwards |

Egress: all, so the host can reach AWS endpoints, Ubuntu mirrors, Docker repo and Let's Encrypt. Restricting egress would need VPC endpoints (cost) or a prefix-list allowlist. We accept open egress as a risk (§5).

## 4. Secrets flow

```
human ──aws ssm put-parameter --type SecureString──▶ /<project>/<env>/DEMO_SECRET  (KMS: aws/ssm)
deploy script (root, on host)
   └─ DEMO_SECRET="$(aws ssm get-parameter --with-decryption …)"   # held in shell memory only
   └─ docker run -e DEMO_SECRET …                                   # name only on argv; value from env
container ── reads env at start ── app validates, never logs it
```

- Not on disk: no env file is written. `-e NAME` without `=value` keeps the value off the process list.
- **Visible to anyone with Docker access** via `docker inspect`. Docker access is root-equivalent anyway, so this is accepted. Only `root` and the deploy user are in the `docker` group.
- The deploy script must never run with `set -x`, and must not echo the variable (Phase 8 review item).
- Rotation: `put-parameter --overwrite`, then redeploy the current SHA. No automatic rotation (ADR 0005).
- The ECR login token is written to `~/.docker/config.json` for its 12 h life. Phase 6 can use `amazon-ecr-credential-helper` to avoid that. Low severity.

## 5. Open risks

| Risk | Severity | Status / next step |
|---|---|---|
| Branch protection on `main` not confirmed | High | Human action before Phase 8 |
| Single instance, single AZ: no HA | Medium | Accepted (ADR 0001) |
| Dependencies pinned by version but not by hash (`--require-hashes`) | Medium | Revisit in Phase 7. Trivy covers known CVEs, not substitution |
| Open egress from the instance | Low | Accepted. Revisit if the app starts handling sensitive data |
| `/version` publicly reveals the deployed git SHA | Low | Accepted: the repo is the source of truth anyway, and it is useful for verifying deploys |
| No WAF or rate limiting | Low | Nginx `limit_req` can be added in Phase 6 if needed |
| Docker `json-file` logs are unbounded by default | Medium (disk-full outage) | Set `log-opts max-size/max-file` in `daemon.json` in Phase 6 |
| Root/admin access of the AWS account itself | — | Outside this repo. Human responsibility |
