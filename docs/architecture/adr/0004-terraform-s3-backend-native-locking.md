# ADR 0004: Terraform S3 backend with native lockfile locking

- Status: Proposed
- Date: 2026-10-24

## Context

State must be remote (laptop loss must not lose it), locked against concurrent applies, versioned for recovery, and encrypted. Historically, S3 locking needed a DynamoDB table.

Verified on 2026-10-24 from the Terraform S3 backend docs:

- v1.10.x docs: `use_lockfile` is "(Experimental, Optional)", and lockfile locking was "introduced as experimental in Terraform 1.10".
- v1.11.x docs: `use_lockfile` is no longer marked experimental. `dynamodb_table` is "(Optional, Deprecated)".
- Latest docs (v1.17.x): "DynamoDB-based locking is deprecated and will be removed in a future minor version." With `use_lockfile`, `s3:GetObject`, `s3:PutObject` and `s3:DeleteObject` are required on the `<key>.tflock` object.

Sources: https://developer.hashicorp.com/terraform/language/v1.10.x/backend/s3, …/v1.11.x/backend/s3, …/backend/s3.

## Decision

- **`required_version = ">= 1.11"`** in every root module. This **challenges CLAUDE.md's "Terraform ≥ 1.10"**: on 1.10 the feature we depend on was experimental. CLAUDE.md should be updated (proposed, not yet changed).
- Backend `s3` with `use_lockfile = true`, `encrypt = true`, and **no** `dynamodb_table`.
- State bucket (in `bootstrap/`): versioning on, SSE, public access block, bucket policy denying non-TLS access, `prevent_destroy`.
- Lock-file permissions (Get/Put/Delete on `*.tflock`) are granted to the operator identity that runs Terraform.
- `bootstrap/` itself uses **local state** (chicken and egg). Its state file stays on the operator's machine and is gitignored (`*.tfstate*`, verified in `.gitignore`). After the first apply, optionally migrate it into the new bucket under `bootstrap/terraform.tfstate`.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| S3 + DynamoDB locking | Deprecated and scheduled for removal. An extra table to create and pay for |
| HCP Terraform / Terraform Cloud state | An external account and service. Hard to justify for a single-operator project. Credentials would leave AWS |
| Local state only | No locking across machines, no versioned recovery, lost with the laptop |
| Terraform 1.10 with the experimental flag | Depends on an experimental feature for the most critical file in the project |

## Consequences

- Local Terraform must be ≥ 1.11. **Terraform is not installed on the operator machine as of 2026-10-24**, which blocks Phase 4. Pin an exact version (e.g. via `.terraform-version` or mise) when installing.
- A stale lock after a crash is cleared with `terraform force-unlock`. That is a human action (it is in the deny list).
- Bootstrap state is a single local file. Losing it doesn't destroy anything, but resources would have to be imported to be managed again.
- State must never contain secret values (ADR 0005), so read access to the bucket is less sensitive. It is still restricted.

## Revisit when

- There is more than one operator or CI starts running `plan`. Then add a CI read-only plan role with access to the state key and lock file.
- Terraform changes the S3 locking model again. Re-check the docs on each Terraform minor upgrade.
