#!/usr/bin/env bash
# Usage: bash tests/docker_smoke.sh IMAGE (image must already be built).
set -euo pipefail
image=${1:?image tag required}
root=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
network="vicohome-smoke-$$"
broker="vicohome-broker-$$"
auth_broker="vicohome-auth-broker-$$"
image_server="vicohome-images-$$"
cleanup() {
  docker rm -f "$broker" "$auth_broker" "$image_server" >/dev/null 2>&1 || true
  docker network rm "$network" >/dev/null 2>&1 || true
}
trap cleanup EXIT
docker network create "$network" >/dev/null
docker run -d --name "$broker" --network "$network" --network-alias broker \
  --entrypoint /bin/sh eclipse-mosquitto:2 -c \
  'printf "listener 1883\nallow_anonymous true\npersistence false\n" > /tmp/smoke.conf; exec mosquitto -c /tmp/smoke.conf' >/dev/null
docker run -d --name "$image_server" --network "$network" --network-alias images \
  --entrypoint /bin/sh nginx:alpine -c \
  'printf "%s" "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGNgaPgPAAIDAYAkYfWXAAAAAElFTkSuQmCC" | base64 -d > /tmp/snapshot.png; printf "server { listen 80; root /tmp; types {} default_type binary/octet-stream; }\n" > /etc/nginx/conf.d/default.conf; exec nginx -g "daemon off;"' >/dev/null
docker run --rm -i --network "$network" --entrypoint /bin/bash "$image" -s < "$root/broker_smoke_inner.sh"

docker run -d --name "$auth_broker" --network "$network" --network-alias authbroker \
  --entrypoint /bin/sh eclipse-mosquitto:2 -c \
  'mosquitto_passwd -b -c /tmp/passwords bridge-user "test password with spaces"; chmod 644 /tmp/passwords; printf "listener 1883\nallow_anonymous false\npassword_file /tmp/passwords\npersistence false\n" > /tmp/smoke.conf; exec mosquitto -c /tmp/smoke.conf' >/dev/null
docker run --rm -i --network "$network" --entrypoint /bin/bash "$image" -s < "$root/mqtt_failure_smoke_inner.sh"
