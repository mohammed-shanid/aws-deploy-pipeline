# ADR 0003: Amazon ECR as the image registry

- Status: Proposed
- Date: 2026-10-24

## Context

CI builds one image per commit on `main`. The instance must pull it without any long-lived credential (hard rule 2), and releases must be identified by an immutable SHA tag.

## Decision

One private ECR repository in the same region as the instance, with:

- **Immutable tags**. A tag is the full git SHA, and pushing the same tag twice fails.
- **Scan on push** (basic scanning), as a second signal after Trivy in CI. Trivy remains the gate.
- **Lifecycle policy** keeping the last N images (N ≥ 10, so manual rollback has history).
- The instance pulls using its **instance role**. CI pushes using its **OIDC role**. Both are scoped to this repository's ARN.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| GitHub Container Registry (private) | The instance would need a GitHub token (PAT or similar) to pull: a long-lived credential on the host, against hard rule 2 |
| GHCR public image | No pull credential needed, but the image (and anything mistakenly baked into it) is public, and AWS-side scanning and lifecycle are lost |
| Docker Hub | Same credential problem as GHCR, plus pull rate limits |
| Build on the instance (no registry) | Build tooling and source on the prod host, no immutable artefact, and CI scans would not be of the thing that runs |

## Consequences

- Storage is ≈ $0.10/GB-month. Same-region pulls to EC2 are free (cost-estimate.md, P4). Expected cost is cents per month.
- `docker login` on the host writes a 12 h token to `~/.docker/config.json`, unless `amazon-ecr-credential-helper` is used (Phase 6 choice; security.md §4).
- Immutability means a bad image can't be "fixed in place". You fix forward with a new SHA, or roll back to an old one. This is the intended behaviour.
- The lifecycle policy can delete an image you might want for rollback. N must exceed the realistic rollback depth.

## Revisit when

- Images must be shared across accounts or regions (ECR replication or a different registry).
- The project moves to a multi-cloud runtime where AWS IAM-based pulls no longer apply.
