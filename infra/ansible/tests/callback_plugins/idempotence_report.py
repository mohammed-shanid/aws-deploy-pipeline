"""Aggregate callback: record every task result per role, write a JSON report.

Enabled only by infra/ansible/tests/idempotence.sh for the second playbook run.
Writes {"roles": {role: {"ok": n, "changed": [task names]}}, "stats": {...}} to
$IDEMPOTENCE_REPORT. Task results are never written, only names and counts, so
module output (which can contain secrets) stays out of the report.
"""

import json
import os
from collections import defaultdict

from ansible.plugins.callback import CallbackBase

DOCUMENTATION = """
name: idempotence_report
type: aggregate
short_description: per-role changed-task report for idempotence checks
description: Writes per-role ok/changed counts to the file named by IDEMPOTENCE_REPORT.
"""

NO_ROLE = "(play tasks)"


class CallbackModule(CallbackBase):
    CALLBACK_VERSION = 2.0
    CALLBACK_TYPE = "aggregate"
    CALLBACK_NAME = "idempotence_report"
    CALLBACK_NEEDS_ENABLED = True

    def __init__(self):
        super().__init__()
        self._roles = defaultdict(lambda: {"ok": 0, "changed": []})

    def _record(self, result):
        task = result._task
        role = task._role.get_name(include_role_fqcn=False) if task._role else NO_ROLE
        entry = self._roles[role]
        entry["ok"] += 1
        if result._result.get("changed", False):
            entry["changed"].append(f"{result._host.get_name()}: {task.get_name()}")

    def v2_runner_on_ok(self, result):
        self._record(result)

    def v2_playbook_on_stats(self, stats):
        report = {
            "roles": dict(self._roles),
            "stats": {h: stats.summarize(h) for h in sorted(stats.processed)},
        }
        path = os.environ.get("IDEMPOTENCE_REPORT")
        if path:
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(report, fh, indent=2, sort_keys=True)
