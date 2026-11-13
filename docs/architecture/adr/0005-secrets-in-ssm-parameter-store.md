# ADR 0005: App secrets in SSM Parameter Store (SecureString)

- Status: Proposed
- Date: 2026-10-24

## Context

The app needs exactly one secret, `DEMO_SECRET`. It is required unless `APP_ENV=dev`, and the app exits 2 at startup without it (`app/config.py`, `app/__main__.py`). Hard rules 2 and 3: no long-lived keys, and secrets are never printed, logged, committed or baked into images. No rotation requirement has been stated.

## Decision

- Store it as a **standard-tier SecureString** at `/<project>/<env>/DEMO_SECRET`, encrypted with the AWS-managed `aws/ssm` KMS key.
- **The human creates and updates the value** with `aws ssm put-parameter --type SecureString` (entered interactively or from a file, never on a shared command line). **Terraform does not manage the parameter**, because any value Terraform manages, or reads through a data source, is written to state in plaintext.
- The instance role may `ssm:GetParameter` only under `/<project>/<env>/*`.
- The on-host deploy script reads it at container start and passes it to Docker via the environment, with no env file on disk (security.md §4).

## Alternatives rejected

| Alternative | Why not |
|---|---|
| AWS Secrets Manager | Paid per secret per month, plus API calls. Its main advantage, managed rotation, is not needed for one static demo secret |
| GitHub Actions secret passed through `send-command` | The secret would transit CI and SSM command parameters, which are visible in command history. CI would hold an app secret it doesn't need |
| Baked into image / build arg | Readable by anyone who can pull the image, and kept in layer history. Forbidden by CLAUDE.md |
| `.env` file on the instance managed by Ansible | The secret sits on disk and in Ansible vars or vault. Harder to rotate |
| Terraform-managed `aws_ssm_parameter` with `ignore_changes = [value]` | A placeholder still goes to state, and refresh can pull the real value into state |
| Customer-managed KMS key | Adds cost (not checked) and key-policy work, with no current requirement (cross-account, separate key admin) |

## Consequences

- Standard parameters and standard-throughput API calls have no charge (cost-estimate.md, P5).
- One manual step per environment: the human must create the parameter **before the first deploy**, or the container exits 2 and the deploy fails safely.
- Rotation = `put-parameter --overwrite`, then redeploy the current SHA. There is a brief window where old and new containers hold different values. That is fine for this app.
- Anyone with `docker inspect` access on the host can read it (accepted; Docker access is root-equivalent).
- Whether the instance role also needs `kms:Decrypt` with the AWS-managed key is to be verified in Phase 5.

## Revisit when

- Secrets need automatic rotation (e.g. a database password) → Secrets Manager.
- Multiple accounts or a separation of key administrators is required → customer-managed KMS key.
- The app gains its own AWS SDK access. Then it could read the parameter itself, but only if IMDS hop limit and role design are revisited (security.md T4).
