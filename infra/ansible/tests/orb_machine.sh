#!/usr/bin/env bash
# Create (if missing) and start the local Ubuntu 24.04 OrbStack machine, then
# wait until Ansible can reach it. Local only: never touches AWS.
#
# Usage: orb_machine.sh [--fresh]
#   --fresh  delete and recreate the machine first (proves roles work from a
#            clean host, not only on top of a previous run)
set -euo pipefail

MACHINE=adp-noble # must match infra/ansible/inventories/local/hosts.yml
IMAGE=ubuntu:noble

ROOT=$(git -C "$(dirname "$0")" rev-parse --show-toplevel)
INVENTORY=$ROOT/infra/ansible/inventories/local/hosts.yml
KNOWN_HOSTS=$ROOT/.harness/known_hosts
PATH=$ROOT/.venv-infra/bin:$PATH

if ! command -v orb > /dev/null 2>&1; then
  echo "orb not found. Install OrbStack (https://orbstack.dev) and open it once." >&2
  exit 127
fi
if ! command -v ansible > /dev/null 2>&1; then
  echo "ansible not found. Run: python3.12 -m venv .venv-infra && .venv-infra/bin/pip install -r requirements-infra.txt" >&2
  exit 127
fi

machine_exists() {
  orb list | awk 'NR > 1 { print $1 }' | grep -qx "$MACHINE"
}

mkdir -p "$ROOT/.harness"

if [[ ${1:-} == --fresh ]] && machine_exists; then
  echo "== deleting $MACHINE (--fresh)"
  orb delete -f "$MACHINE"
fi

if ! machine_exists; then
  echo "== creating $MACHINE from $IMAGE"
  orb create "$IMAGE" "$MACHINE"
  # New machine, new host key.
  rm -f "$KNOWN_HOSTS"
fi

orb start "$MACHINE" > /dev/null 2>&1 || true

# Fail early if the image is not the Ubuntu release AWS runs.
# shellcheck disable=SC2016 # expanded inside the machine, not here
version=$(orb -m "$MACHINE" sh -c '. /etc/os-release && echo "$ID $VERSION_ID"')
if [[ $version != "ubuntu 24.04" ]]; then
  echo "expected ubuntu 24.04 on $MACHINE, found: $version" >&2
  exit 1
fi

# "degraded" is normal in a container-style machine; only wait for boot to finish.
orb -m "$MACHINE" -u root systemctl is-system-running --wait > /dev/null 2>&1 || true

echo "== $MACHINE: $version, $(orb -m "$MACHINE" uname -m)"
ansible -i "$INVENTORY" "$MACHINE" -m ansible.builtin.ping -o
