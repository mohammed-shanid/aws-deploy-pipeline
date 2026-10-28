# Cost estimate

**Every figure here is an estimate.** On-demand list prices, USD, before tax and credits. Free Tier is **not** subtracted for EC2: Free Tier terms vary by account age and changed for newer accounts, so we did not rely on them. Month = 730 hours.
Region is not decided yet (architecture.md §6), so both `us-east-1` and `ap-south-1` are shown. Prices checked **2026-10-24**.

## Sources (checked 2026-10-24)

| Ref | Page | How read |
|---|---|---|
| P1 | https://aws.amazon.com/ec2/pricing/on-demand/ | Table data from the page's own pricing JSON (`b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/…/ec2-ondemand-without-sec-sel/<region>/Linux/index.json`) |
| P2 | https://aws.amazon.com/vpc/pricing/ | Public IPv4 $0.005/h (in-use or idle). NAT Gateway shown for us-east-2 |
| P3 | https://aws.amazon.com/ebs/pricing/ | Page pricing JSON (`…/ec2/USD/current/ebs.json`) |
| P4 | https://aws.amazon.com/ecr/pricing/ | Storage $0.10/GB-month. Same-region transfer to EC2 free |
| P5 | https://aws.amazon.com/systems-manager/pricing/ | Standard parameters and Run Command/Session Manager on EC2: no charge |
| P6 | https://aws.amazon.com/cloudwatch/pricing/ | Free tier and us-east-1 examples |
| P7 | https://aws.amazon.com/elasticloadbalancing/pricing/ | ALB, us-east-1 example |

## Recurring drivers (chosen design)

| Driver | Unit price us-east-1 | Unit price ap-south-1 | Assumed usage | Est. /month us-east-1 | Est. /month ap-south-1 | Ref |
|---|---|---|---|---|---|---|
| EC2 `t3.small` (2 vCPU, 2 GiB) | $0.0208/h | $0.0224/h | 730 h | **$15.18** | **$16.35** | P1 |
| Public IPv4 (Elastic IP) | $0.005/h | $0.005/h (page lists one rate) | 1 address | **$3.65** | **$3.65** | P2 |
| EBS gp3 root | $0.08/GB-mo | $0.0912/GB-mo | 20 GB (8 GB default is tight with Docker images) | **$1.60** | **$1.82** | P3 |
| ECR storage | $0.10/GB-mo | not checked | ~10 images × ~60 MB ≈ 0.6 GB (image size is a guess until Phase 7) | ~$0.06 | ~$0.06 | P4 |
| SSM Parameter Store (standard), Run Command, Session Manager | $0 | $0 | 1 parameter | $0 | $0 | P5 |
| CloudWatch custom metrics | 10 free, then $0.30/metric | — | ~2–4 (mem, disk) | $0 if ≤ 10 | $0 if ≤ 10 | P6 |
| CloudWatch alarms (standard) | 10 free, then $0.10/alarm | — | ~6 | $0 if ≤ 10 | $0 if ≤ 10 | P6 |
| CloudWatch Logs | 5 GB free, then $0.50/GB ingest | — | < 1 GB/month at demo traffic | $0 | $0 | P6 |
| **Total (chosen design)** | | | | **≈ $20.50** | **≈ $21.90** | |

Not checked, and expected to be well under $1/month at this scale: S3 state bucket storage and requests, KMS requests for `aws/ssm`, SNS email, AWS Budgets, internet data transfer out. Check these before relying on the totals.

## Options that change the bill

| Option | Est. /month us-east-1 | Est. /month ap-south-1 | Note | Ref |
|---|---|---|---|---|
| `t3.micro` (1 GiB) instead of `t3.small` | $7.59 (−$7.59) | $8.18 (−$8.17) | Rejected for now: memory pressure (architecture.md §5.5) | P1 |
| `t4g.small` (Graviton, 2 GiB) | $12.26 (−$2.92) | **$8.18 (−$8.17)** | Needs arm64 images. In ap-south-1 the saving is ~50%, which may justify the build work | P1 |
| Stop the instance when not in use | EC2 line × fraction running | same | The EIP is still charged while the instance is stopped | P1, P2 |

## Rejected components (why the ADRs matter)

| Component | Est. /month | Ref |
|---|---|---|
| NAT Gateway | ≈ $32.85 + $0.045/GB processed (us-east-2 price; us-east-1 not shown on page) | P2 |
| Application Load Balancer | ≈ $16.43 + $0.008/LCU-h (≥ ~$5.84 for 1 LCU continuously) | P7 |
| Interface VPC endpoints (to avoid public egress) | Not checked. Several endpoints (ssm, ssmmessages, ec2messages, ecr.api, ecr.dkr, logs) are each billed hourly per AZ, likely more than the instance | — |
| CloudWatch Synthetics canary, every 5 min | 8,640 runs × $0.0012 − 100 free ≈ $10.25 (Phase 9 ADR compares it with a Route 53 health check) | P6 |

## Tripwire

Phase 4 creates an AWS Budget with an email alert. A threshold of about **$25/month** sits just above the estimate above, so a stray NAT Gateway or ALB would trigger it within the month. The human sets the amount.
