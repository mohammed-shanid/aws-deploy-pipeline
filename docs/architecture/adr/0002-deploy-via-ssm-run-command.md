# ADR 0002: Deploy via SSM Run Command, not SSH from CI

- Status: Proposed
- Date: 2026-10-24

## Context

CI (GitHub-hosted runners) must tell the instance to run a new image SHA. GitHub-hosted runner IPs are many and change, so allowing SSH from CI would mean opening 22 broadly, which hard rule 5 forbids. It would also need a private key stored as a CI secret, a long-lived credential. The instance already runs the SSM agent for Session Manager.

## Decision

- CI calls `ssm:SendCommand` using its OIDC-assumed role. The SSM agent on the host connects **outbound**, so no inbound port is needed.
- CI runs a **custom Command document `<project>-deploy`**, not `AWS-RunShellScript`. Its one parameter `sha` has `allowedPattern: ^[0-9a-f]{40}$`, and it runs exactly `/opt/app/bin/deploy {{ sha }}`.
- The deploy role's `ssm:SendCommand` is scoped to that **document ARN and the instance ARN** only.
- CI waits for the invocation, reads its status, and fails on a non-zero exit. Output also goes to a CloudWatch log group, because API output is truncated.

**This challenges the plan as written.** "ssm:SendCommand to this instance" with `AWS-RunShellScript` would let any workflow on `main` run arbitrary commands as root on the host. That makes CI a root shell, which is not a deploy permission. The custom document limits CI to "deploy SHA X".

## Alternatives rejected

| Alternative | Why not |
|---|---|
| SSH from CI | Needs 22 open to GitHub's IP ranges and a private key in CI secrets (long-lived credential, hard rule 2) |
| SSH via a self-hosted runner on the instance | The runner process holds repo access on the prod host. A compromised workflow becomes a compromised host. Patching the runner is another chore |
| Pull-based: host polls ECR or a parameter for a "desired SHA" (cron/systemd timer) | Good decoupling, but CI can't easily report pass/fail of the actual deploy. That breaks "on failure … fail the pipeline". Worth revisiting |
| `AWS-RunShellScript` scoped to the instance | Equivalent to root for CI (see above) |
| CodeDeploy | Another managed service and agent, for the same result as one script (hard rule 7) |

## Consequences

- The SSM agent must be online. If it isn't, deploys fail (pipeline red, site unchanged); break-glass is in deployment.md §5.
- The workflow needs a polling/wait step (`aws ssm wait command-executed` or a loop on `get-command-invocation`) and a timeout longer than the script's health-poll window.
- Changing the deploy contract (new parameters) means a Terraform change to the document.
- Session Manager access by humans is still root-equivalent. That is controlled by human IAM, not by this ADR.
- Run Command on EC2 has no additional charge (cost-estimate.md, P5).

## Revisit when

- There is more than one instance → consider target-by-tag with rate control, or move to a pull model or a container service.
- SSM availability causes repeated failed deploys.
