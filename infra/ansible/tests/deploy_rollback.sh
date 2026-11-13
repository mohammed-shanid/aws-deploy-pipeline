#!/usr/bin/env bash
# Local deploy/rollback test on the OrbStack machine. Never touches AWS.
#
# Deploys the image built from this checkout (tagged with HEAD's full SHA), then
# two deliberately broken releases, and asserts the good release's container
# keeps serving /version throughout. The steps run in deploy_rollback_inner.sh.
#
# Prerequisites: idempotence.sh has configured the machine (Docker, Nginx with
# the self-signed cert, deploy script) and the repo has a Dockerfile.
set -euo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
MACHINE=adp-noble # must match infra/ansible/inventories/local/hosts.yml
INVENTORY=$ROOT/infra/ansible/inventories/local/hosts.yml
PATH=$ROOT/.venv-infra/bin:$PATH

"$HERE/orb_machine.sh"

GOOD_SHA=$(git -C "$ROOT" rev-parse HEAD)
if [[ -n $(git -C "$ROOT" status --porcelain) ]]; then
  echo "note: uncommitted changes; the image is built from the working tree but tagged $GOOD_SHA"
fi
# Broken releases need their own valid 40-hex tags; derive stable ones from HEAD.
derive_sha() { printf '%s:%s' "$1" "$GOOD_SHA" | shasum -a 1 | cut -c1-40; }

vars=$(ansible-inventory -i "$INVENTORY" --host "$MACHINE")
var() { python3 -c 'import json, sys; print(json.loads(sys.argv[1])[sys.argv[2]])' "$vars" "$1"; }

orb -m "$MACHINE" -u root env \
  REPO_ROOT="$ROOT" \
  GOOD_SHA="$GOOD_SHA" \
  BAD_HEALTH_SHA="$(derive_sha broken-health)" \
  BAD_CRASH_SHA="$(derive_sha broken-crash)" \
  IMAGE_REPO="$(var image_repo)" \
  APP_DOMAIN="$(var app_domain)" \
  TLS_CERT_PATH="$(var tls_cert_path)" \
  bash "$HERE/deploy_rollback_inner.sh"
