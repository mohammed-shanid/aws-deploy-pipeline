"""Fail unless the report from idempotence_report shows a run with zero changes.

Usage: check_idempotence.py <report.json>
Prints a per-role table so a failure names the role and task that is not idempotent.
"""

import json
import sys


def main(path: str) -> int:
    with open(path, encoding="utf-8") as fh:
        report = json.load(fh)

    roles = report.get("roles", {})
    stats = report.get("stats", {})
    if not roles or not stats:
        print("FAIL: the second run executed no tasks; nothing was checked")
        return 1

    print(f"{'role':30} {'tasks':>6} {'changed':>8}")
    changed_tasks = []
    for role in sorted(roles):
        entry = roles[role]
        print(f"{role:30} {entry['ok']:>6} {len(entry['changed']):>8}")
        changed_tasks += [f"  [{role}] {t}" for t in entry["changed"]]

    bad_hosts = {
        host: s
        for host, s in stats.items()
        if s.get("changed") or s.get("failures") or s.get("unreachable")
    }
    for host, s in sorted(stats.items()):
        print(
            f"recap {host}: ok={s.get('ok')} changed={s.get('changed')} "
            f"failed={s.get('failures')} unreachable={s.get('unreachable')}"
        )

    if changed_tasks or bad_hosts:
        print("FAIL: second run is not idempotent. Changed tasks:")
        print("\n".join(changed_tasks) or "  (none recorded; see recap)")
        return 1
    print("PASS: second run reported changed=0 for every role")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1]))
