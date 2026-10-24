"""Prove the Terraform guardrails catch what they claim to: mutation testing.

Usage: python3 infra/tests/terraform_mutation/mutate.py   (from the repo root)
Needs: terraform >= 1.7 on PATH (mise.toml pins it), network for the first
provider download, and checkov in .venv-infra (requirements-infra.txt).
Override the binaries with TERRAFORM=... and CHECKOV=....

1. Copies fixture/main.tf (a minimal config that meets the test contract) and the
   repo's real guardrails.tftest.hcl into a temp dir. The tests are never copied
   from anywhere else, so this always checks the committed tests.
2. Baseline: the fixture must pass every run.
3. Applies each mutation below on its own (one rule broken), and requires that
   `terraform test` fails in exactly the run named for it. A mutation caught by the
   wrong run, or by several, counts as a failure: it means a test is not checking
   what its name says.
4. Same for checkov's CKV_ADP_1 (provider default_tags): baseline passes, each
   tag mutation fails.

Exit 0 only if the baseline passes and every mutation is caught as expected.
"""

import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

REPO = Path(__file__).resolve().parents[3]
FIXTURE = Path(__file__).resolve().parent / "fixture"
TESTS = REPO / "infra/terraform/envs/dev/tests/guardrails.tftest.hcl"
CHECKS_DIR = REPO / "infra/terraform/checkov"
TERRAFORM = os.environ.get("TERRAFORM", "terraform")
CHECKOV = os.environ.get("CHECKOV", str(REPO / ".venv-infra/bin/checkov"))

RUNS = [
    "required_tags",
    "no_ssh_ingress_by_default",
    "ssh_rejects_non_slash_32",
    "imdsv2_required",
    "ebs_encrypted",
    "oidc_trust_pinned_to_repo_main",
]

TRUST_EQUALS = (
    "StringEquals = {\n"
    '          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"\n'
    '          "token.actions.githubusercontent.com:sub"'
    ' = "repo:${var.github_repo}:ref:refs/heads/main"\n'
    "        }"
)
TRUST_LIKE = (
    "StringEquals = {\n"
    '          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"\n'
    "        }\n"
    "        StringLike = {\n"
    '          "token.actions.githubusercontent.com:sub" = "repo:${var.github_repo}:*"\n'
    "        }"
)
METADATA = (
    "  metadata_options {\n"
    '    http_endpoint               = "enabled"\n'
    '    http_tokens                 = "required"\n'
    "    http_put_response_hop_limit = 1\n"
    "  }\n"
)
ROOT_BLOCK = '  root_block_device {\n    encrypted   = true\n    volume_type = "gp3"\n  }\n'
INLINE_SSH = (
    '  tags   = { Name = "app" }\n'
    "  ingress {\n"
    "    from_port   = 22\n"
    "    to_port     = 22\n"
    '    protocol    = "tcp"\n'
    '    cidr_blocks = ["0.0.0.0/0"]\n'
    "  }\n}"
)
CIDR_RULE = (
    "    condition     = var.operator_cidr == null || (can(cidrhost(var.operator_cidr, 0))"
    ' && endswith(coalesce(var.operator_cidr, "x"), "/32"))'
)

# name: (text in fixture/main.tf, replacement, run expected to fail)
TF_MUTATIONS = {
    "tag_missing_owner": ("    Owner       = var.owner\n", "", "required_tags"),
    "tag_override": (
        'tags   = { Name = "app" }',
        'tags   = { Name = "app", Owner = "" }',
        "required_tags",
    ),
    "ssh_public_rule": (
        "{ http = 80, https = 443 }",
        "{ http = 80, https = 443, ssh = 22 }",
        "no_ssh_ingress_by_default",
    ),
    "port_range_covers_22": (
        "  from_port         = each.value\n",
        "  from_port         = each.value == 80 ? 0 : each.value\n",
        "no_ssh_ingress_by_default",
    ),
    "inline_ingress_22": (
        '  tags   = { Name = "app" }\n}',
        INLINE_SSH,
        "no_ssh_ingress_by_default",
    ),
    "ssh_open_by_default": (
        "  default = null\n  validation",
        '  default = "203.0.113.7/32"\n  validation',
        "no_ssh_ingress_by_default",
    ),
    # Weakened, not removed: Terraform rejects a condition that ignores the variable as
    # invalid config, which would fail for the wrong reason.
    "cidr_not_limited_to_32": (
        CIDR_RULE,
        "    condition     = var.operator_cidr == null || can(cidrhost(var.operator_cidr, 0))",
        "ssh_rejects_non_slash_32",
    ),
    "imdsv1_allowed": (
        'http_tokens                 = "required"',
        'http_tokens                 = "optional"',
        "imdsv2_required",
    ),
    "imds_block_missing": (METADATA, "", "imdsv2_required"),
    "hop_limit_2": (
        "http_put_response_hop_limit = 1",
        "http_put_response_hop_limit = 2",
        "imdsv2_required",
    ),
    "root_unencrypted": ("encrypted   = true", "encrypted   = false", "ebs_encrypted"),
    "root_block_missing": (ROOT_BLOCK, "", "ebs_encrypted"),
    "extra_ebs_unencrypted": (
        '    volume_type = "gp3"\n  }\n',
        '    volume_type = "gp3"\n  }\n'
        '  ebs_block_device {\n    device_name = "/dev/sdf"\n    volume_size = 8\n  }\n',
        "ebs_encrypted",
    ),
    "sub_stringlike_wildcard": (TRUST_EQUALS, TRUST_LIKE, "oidc_trust_pinned_to_repo_main"),
    "sub_other_repo": (
        'default = "mohammed-shanid/aws-deploy-pipeline"',
        'default = "someone-else/aws-deploy-pipeline"',
        "oidc_trust_pinned_to_repo_main",
    ),
    "sub_other_branch": (
        ':ref:refs/heads/main"',
        ':ref:refs/heads/dev"',
        "oidc_trust_pinned_to_repo_main",
    ),
    "aud_missing": (
        '          "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com"\n',
        "",
        "oidc_trust_pinned_to_repo_main",
    ),
    "oidc_wrong_url": (
        'url            = "https://token.actions.githubusercontent.com"',
        'url            = "https://example.com"',
        "oidc_trust_pinned_to_repo_main",
    ),
}

# name: (text in fixture/main.tf, replacement). Each must make CKV_ADP_1 fail.
CKV_MUTATIONS = {
    "no_default_tags": ("  default_tags { tags = local.common_tags }\n", ""),
    "default_tags_missing_owner": ("    Owner       = var.owner\n", ""),
    "managed_by_not_terraform": ('ManagedBy   = "terraform"', 'ManagedBy   = "hand"'),
    "aliased_provider_untagged": (
        'data "aws_availability_zones"',
        'provider "aws" {\n  alias  = "use1"\n  region = "us-east-1"\n}\n\n'
        'data "aws_availability_zones"',
    ),
}


def run(cmd: list[str], cwd: Path) -> subprocess.CompletedProcess:
    # Fixed argv from this file, no shell.
    return subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)  # noqa: S603


def mutate(src: str, name: str, old: str, new: str) -> str:
    if src.count(old) != 1:
        sys.exit(f"ERROR {name}: pattern must occur exactly once in fixture/main.tf")
    return src.replace(old, new)


def tf_test(work: Path) -> tuple[int, list[str], str]:
    r = run([TERRAFORM, "test", "-no-color"], work)
    out = r.stdout + r.stderr
    failed = re.findall(r'run "([^"]+)"\.\.\. fail', out)
    summary = re.search(r"\d+ passed, \d+ failed[^\n]*", out)
    return r.returncode, failed, summary.group(0) if summary else out.strip()[-200:]


def ckv(work: Path) -> int:
    # cwd is the temp dir, so the repo's .checkov.yaml is not read; only CKV_ADP_1 runs.
    cmd = [CHECKOV, "-f", "main.tf", "--framework", "terraform", "--check", "CKV_ADP_1"]
    cmd += ["--external-checks-dir", str(CHECKS_DIR), "--compact", "--quiet"]
    return run(cmd, work).returncode


def main() -> int:
    good = (FIXTURE / "main.tf").read_text()
    ok = True
    with tempfile.TemporaryDirectory(prefix="tf-mutation-") as tmp:
        work = Path(tmp)
        shutil.copy(FIXTURE / "main.tf", work)
        shutil.copy(FIXTURE / ".terraform.lock.hcl", work)
        (work / "tests").mkdir()
        shutil.copy(TESTS, work / "tests")

        for cmd in (
            [TERRAFORM, "fmt", "-check", "main.tf"],
            [TERRAFORM, "init", "-backend=false", "-input=false", "-lockfile=readonly"],
        ):
            r = run(cmd, work)
            if r.returncode != 0:
                print(r.stdout + r.stderr)
                sys.exit(f"ERROR: {' '.join(cmd[1:3])} failed")

        code, failed, summary = tf_test(work)
        print(f"terraform test, baseline: {summary}")
        if code != 0 or failed:
            print(f"FAIL baseline: fixture must pass every run, failed={failed}")
            return 1

        print(f"\n{'result':8} {'mutation':26} {'expected run':32} failed runs")
        for name, (old, new, expected) in TF_MUTATIONS.items():
            (work / "main.tf").write_text(mutate(good, name, old, new))
            code, failed, summary = tf_test(work)
            caught = code != 0 and failed == [expected]
            ok &= caught
            label = "CAUGHT" if caught else "WRONG" if failed else "MISSED"
            print(f"{label:8} {name:26} {expected:32} {failed or summary}")
        (work / "main.tf").write_text(good)

        print()
        if ckv(work) != 0:
            print("FAIL baseline: CKV_ADP_1 must pass on the fixture")
            return 1
        print("checkov CKV_ADP_1, baseline: passed")
        for name, (old, new) in CKV_MUTATIONS.items():
            (work / "main.tf").write_text(mutate(good, name, old, new))
            caught = ckv(work) != 0
            ok &= caught
            print(f"{'CAUGHT' if caught else 'MISSED':8} CKV_ADP_1 {name}")

    total = len(TF_MUTATIONS) + len(CKV_MUTATIONS)
    print(f"\n{'ALL' if ok else 'NOT ALL'} {total} MUTATIONS CAUGHT AS EXPECTED")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
