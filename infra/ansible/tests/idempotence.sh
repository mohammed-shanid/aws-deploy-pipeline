#!/usr/bin/env bash
# Run the playbook twice against the local OrbStack machine; the second run
# must report changed=0. Local only: never touches AWS.
#
# Usage: idempotence.sh [--fresh] [--role NAME]
#   --fresh      recreate the machine first (see orb_machine.sh)
#   --role NAME  test one role on its own instead of site.yml
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
ANSIBLE_DIR=$ROOT/infra/ansible
INVENTORY=$ANSIBLE_DIR/inventories/local/hosts.yml
REPORT=$ROOT/.harness/idempotence.json
PATH=$ROOT/.venv-infra/bin:$PATH

fresh=()
role=""
while (($#)); do
  case $1 in
    --fresh) fresh=(--fresh) ;;
    --role) role=${2:?--role needs a name}; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
  shift
done

if [[ -n $role ]]; then
  [[ -d $ANSIBLE_DIR/roles/$role ]] || { echo "no role at infra/ansible/roles/$role" >&2; exit 2; }
  mkdir -p "$ROOT/.harness"
  playbook=$ROOT/.harness/role-$role.yml
  printf -- '- name: Idempotence check for role %s\n  hosts: local\n  become: true\n  roles:\n    - %s\n' \
    "$role" "$role" > "$playbook"
  export ANSIBLE_ROLES_PATH=$ANSIBLE_DIR/roles
else
  playbook=$ANSIBLE_DIR/site.yml
  [[ -f $playbook ]] || { echo "no playbook at infra/ansible/site.yml (Phase 6 creates it)" >&2; exit 2; }
fi

"$HERE/orb_machine.sh" "${fresh[@]+"${fresh[@]}"}"

# Run from infra/ansible so its ansible.cfg (if any) applies.
cd "$ANSIBLE_DIR"

echo "== run 1: $playbook"
ansible-playbook -i "$INVENTORY" "$playbook"

echo "== run 2: must report changed=0"
rm -f "$REPORT"
ANSIBLE_CALLBACK_PLUGINS=$HERE/callback_plugins \
  ANSIBLE_CALLBACKS_ENABLED=idempotence_report \
  IDEMPOTENCE_REPORT=$REPORT \
  ansible-playbook -i "$INVENTORY" "$playbook"

python3 "$HERE/check_idempotence.py" "$REPORT"
