#!/usr/bin/env bash
# Runs as root inside the local OrbStack machine. Started by deploy_rollback.sh;
# do not run it on an AWS host (it builds images and starts a local registry).
#
# Deploys a good release, then two broken ones (/health returns 500; crash on
# start). Each broken deploy must exit non-zero while the good release's
# container keeps serving /version through Nginx, with no failed request.
#
# Contract with the Phase 8 deploy script (see docs/architecture/deployment.md):
#   /opt/app/bin/deploy <40-hex sha>   exit 0 = released; non-zero = old release untouched
#   /opt/app/state/current, previous   first line is the SHA
#   label adp.app=aws-deploy-pipeline  on every app container it starts
#   HEALTH_TIMEOUT_SECONDS             env override of the health-poll window
set -euo pipefail

: "${REPO_ROOT:?}" "${GOOD_SHA:?}" "${BAD_HEALTH_SHA:?}" "${BAD_CRASH_SHA:?}"
: "${IMAGE_REPO:?}" "${APP_DOMAIN:?}" "${TLS_CERT_PATH:?}"

# registry 3.1.1, published 2026-09-21. Test fixture only; never used on AWS.
REGISTRY_IMAGE=registry:3.1.1@sha256:325b4b29b041e82803abeb703e201655e4e23ab83264ec1a7c9ddb0a5b14a6e0
REGISTRY_NAME=adp-test-registry
DEPLOY=/opt/app/bin/deploy
STATE_DIR=/opt/app/state
APP_LABEL=adp.app=aws-deploy-pipeline
FIXTURE_DIR=$REPO_ROOT/infra/ansible/tests/fixtures/broken
export HEALTH_TIMEOUT_SECONDS=${HEALTH_TIMEOUT_SECONDS:-20}

WORK=$(mktemp -d)
poller=""
cleanup() {
  [[ -n $poller ]] && kill "$poller" 2> /dev/null || true
  rm -rf "$WORK"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $*" >&2
  exit 1
}
step() { printf '\n== %s\n' "$*"; }

version_via_nginx() {
  curl -fsS --max-time 3 --cacert "$TLS_CERT_PATH" \
    --resolve "$APP_DOMAIN:443:127.0.0.1" "https://$APP_DOMAIN/version" |
    python3 -c 'import json, sys; print(json.load(sys.stdin)["git_sha"])'
}
state() { head -n1 "$STATE_DIR/$1" 2> /dev/null || echo "(none)"; }
app_containers() { docker ps --filter "label=$APP_LABEL" --format '{{.ID}} {{.Image}}'; }

step "preconditions"
[[ -x $DEPLOY ]] || fail "$DEPLOY missing: run the playbook first (Phase 8 installs it)"
[[ -f $REPO_ROOT/Dockerfile ]] || fail "no $REPO_ROOT/Dockerfile (Phase 7), or the Mac path is not visible in the machine"
[[ -f $TLS_CERT_PATH ]] || fail "no certificate at $TLS_CERT_PATH (nginx role with tls_mode=selfsigned)"
for cmd in docker curl python3; do
  command -v "$cmd" > /dev/null || fail "$cmd not installed"
done
systemctl is-active --quiet nginx || fail "nginx is not running"
echo "ok"

step "local registry on 127.0.0.1:5000"
if ! docker inspect "$REGISTRY_NAME" > /dev/null 2>&1; then
  docker run -d --name "$REGISTRY_NAME" --restart unless-stopped \
    -p 127.0.0.1:5000:5000 "$REGISTRY_IMAGE" > /dev/null
fi
docker start "$REGISTRY_NAME" > /dev/null
for _ in $(seq 20); do
  curl -fsS -o /dev/null http://127.0.0.1:5000/v2/ && break
  sleep 0.5
done
curl -fsS -o /dev/null http://127.0.0.1:5000/v2/ || fail "registry did not start"
echo "ok"

step "build and push good release $GOOD_SHA"
docker build -t "$IMAGE_REPO:$GOOD_SHA" "$REPO_ROOT"
docker push -q "$IMAGE_REPO:$GOOD_SHA"

step "build and push broken releases"
build_broken() { # mode sha
  docker build -q --build-arg "BASE_IMAGE=$IMAGE_REPO:$GOOD_SHA" --build-arg "BROKEN_MODE=$1" \
    -t "$IMAGE_REPO:$2" "$FIXTURE_DIR" > /dev/null
  docker push -q "$IMAGE_REPO:$2"
}
build_broken health500 "$BAD_HEALTH_SHA"
build_broken crash "$BAD_CRASH_SHA"

# A broken fixture that is accidentally healthy would make this test pass for
# the wrong reason, so prove each one is broken in the intended way first.
step "self-test the broken fixtures"
cid=$(docker run -d --rm -p 127.0.0.1::8000 -e HOST=0.0.0.0 "$IMAGE_REPO:$BAD_HEALTH_SHA")
port=$(docker port "$cid" 8000/tcp | head -n1 | sed 's/.*://')
code=000
for _ in $(seq 20); do
  code=$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$port/health" || true)
  [[ $code == 500 ]] && break
  sleep 0.5
done
docker rm -f "$cid" > /dev/null
[[ $code == 500 ]] || fail "health500 fixture returned $code, not 500"
rc=0
docker run --rm "$IMAGE_REPO:$BAD_CRASH_SHA" > /dev/null 2>&1 || rc=$?
[[ $rc == 3 ]] || fail "crash fixture exited $rc, not 3"
echo "ok: health500 serves 500, crash exits 3"

step "deploy good release"
"$DEPLOY" "$GOOD_SHA" || fail "deploy of the good release failed"
[[ $(version_via_nginx) == "$GOOD_SHA" ]] || fail "/version does not report $GOOD_SHA after deploy"
[[ $(state current) == "$GOOD_SHA" ]] || fail "state/current is $(state current), not $GOOD_SHA"
[[ $(app_containers | wc -l) -eq 1 ]] || fail "expected one app container, found: $(app_containers)"
echo "ok: $GOOD_SHA serving"

for case in "health500 $BAD_HEALTH_SHA" "crash $BAD_CRASH_SHA"; do
  read -r mode bad_sha <<< "$case"
  step "deploy broken release ($mode) $bad_sha: must fail, $GOOD_SHA must keep serving"
  containers_before=$(app_containers)
  previous_before=$(state previous)
  polls=$WORK/polls-$mode

  # Hit /version through Nginx for the whole deploy.
  (
    while [[ ! -f $WORK/stop ]]; do
      version_via_nginx 2> /dev/null || echo ERROR
      sleep 0.2
    done
  ) > "$polls" &
  poller=$!

  rc=0
  "$DEPLOY" "$bad_sha" || rc=$?

  touch "$WORK/stop"
  wait "$poller"
  poller=""
  rm -f "$WORK/stop"

  [[ $rc -ne 0 ]] || fail "deploy of a broken release exited 0"
  total=$(wc -l < "$polls")
  wrong=$(grep -cvx "$GOOD_SHA" "$polls" || true)
  [[ $total -gt 0 ]] || fail "no requests were made during the deploy"
  [[ $wrong -eq 0 ]] || fail "$wrong of $total requests during the deploy did not return $GOOD_SHA: $(sort "$polls" | uniq -c | tr '\n' ' ')"
  [[ $(version_via_nginx) == "$GOOD_SHA" ]] || fail "/version no longer reports $GOOD_SHA"
  [[ $(app_containers) == "$containers_before" ]] || fail "app container changed: was [$containers_before], now [$(app_containers)]"
  [[ $(state current) == "$GOOD_SHA" ]] || fail "state/current changed to $(state current)"
  [[ $(state previous) == "$previous_before" ]] || fail "state/previous changed to $(state previous)"
  [[ -z $(docker ps -aq --filter "ancestor=$IMAGE_REPO:$bad_sha") ]] || fail "the broken container was left behind"
  echo "PASS: deploy exited $rc; $total/$total requests served $GOOD_SHA by the same container"
done

step "PASS: good release kept serving through both broken deploys"
echo "Left running for inspection: $GOOD_SHA and the $REGISTRY_NAME container."
