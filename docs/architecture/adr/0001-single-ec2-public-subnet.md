# ADR 0001: Single EC2 instance in a public subnet, no ALB, no NAT Gateway

- Status: Proposed
- Date: 2026-10-24

## Context

The workload is a stateless FastAPI service with a `/health` endpoint (verified in `app/main.py`). It has no database, no stored files and no outbound integrations. The goal (CLAUDE.md) is a system that one engineer can build, break and recover, at the lowest reasonable cost. No uptime SLO has been stated.

## Decision

- One EC2 instance (`t3.small`, Ubuntu LTS) in **one public subnet**, with an Elastic IP.
- TLS is terminated on the instance by Nginx with a Let's Encrypt certificate.
- **No ALB, no NAT Gateway, and no private subnets.** The instance reaches AWS APIs outbound through the internet gateway.
- Zero-downtime releases use two container slots behind Nginx on the same host (deployment.md).

The prompt asked for private subnets to be explained or dropped. **We drop them.** Nothing runs in them, and a private subnet with no NAT and no endpoints can't even pull images. Their only effect would be extra code and a standing temptation to add a NAT Gateway.

## Alternatives rejected

| Alternative | Why not |
|---|---|
| ALB + Auto Scaling group (≥ 2 instances) | ≈ $16+/month for the ALB plus a second instance. HA is not a stated requirement. More moving parts than one person needs to learn break/fix here |
| Instance in a private subnet behind a NAT Gateway | ≈ $33+/month, more than the instance itself. Gains nothing: inbound 80/443 must be public anyway |
| Private subnet with VPC interface endpoints instead of NAT | Several hourly-billed endpoints. Still needs a public entry point (ALB) for users |
| ECS Fargate / App Runner / Lambda | Valid for production, but they hide the host-level skills this repo exists to practise (Ansible, Nginx, systemd, disk/cert incidents). Hard rule 7 also requires an ADR for extra managed services |
| Lightsail | Cheaper, but outside the VPC, IAM-role and SSM model the rest of the design uses |

## Consequences

- Single point of failure: instance, AZ or host-level faults cause downtime until rebuild. The app being stateless keeps rebuild simple.
- The instance has a public IP, so SG + ufw + loopback-only app binding are the whole perimeter (security.md §3).
- The Elastic IP costs ≈ $3.65/month (cost-estimate.md).
- The certificate lives on the host. Renewal and expiry monitoring are our responsibility (Phases 6 and 9).
- Rebuilding the instance changes its ID, so CI must look it up (by tag or Terraform output) rather than hardcode it.

## Revisit when

- An uptime SLO is stated, or there is paying or production traffic → ALB + ≥ 2 instances or a container service.
- A database or other component appears that must not be internet-reachable → add private subnets in that change, and choose NAT vs endpoints with a cost ADR.
- The instance is CPU- or memory-bound at `t3.small`.
