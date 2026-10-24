"""CKV_ADP_1: every AWS provider block sets the required tags through default_tags.

Checkov does not merge provider default_tags into resources, so a per-resource
tag policy would fail every resource that relies on them. This check covers the
provider instead; together with default_tags that reaches every taggable
resource. The plan-time proof (tags_all on each resource) needs a real plan and
runs on AWS only: see docs/architecture/deployment.md, "Local test harness".
"""

from checkov.common.models.enums import CheckCategories, CheckResult
from checkov.terraform.checks.provider.base_check import BaseProviderCheck

REQUIRED_TAGS = ("Project", "Environment", "Owner", "ManagedBy")


class RequiredDefaultTags(BaseProviderCheck):
    def __init__(self) -> None:
        super().__init__(
            name="AWS provider default_tags set Project, Environment, Owner, ManagedBy=terraform",
            id="CKV_ADP_1",
            categories=[CheckCategories.CONVENTION],
            supported_provider=("aws",),
        )

    def scan_provider_conf(self, conf: dict) -> CheckResult:
        try:
            tags = conf["default_tags"][0]["tags"][0]
        except (KeyError, IndexError, TypeError):
            return CheckResult.FAILED
        # An unresolved reference (a string, not a map) cannot be verified: fail closed.
        if not isinstance(tags, dict):
            return CheckResult.FAILED
        for key in REQUIRED_TAGS:
            value = tags.get(key)
            if not isinstance(value, str) or not value.strip():
                return CheckResult.FAILED
        if tags["ManagedBy"] != "terraform":
            return CheckResult.FAILED
        return CheckResult.PASSED


check = RequiredDefaultTags()
