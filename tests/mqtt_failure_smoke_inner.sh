#!/usr/bin/env bash
set -e
# Real Bashio + authenticated MQTT, with a deterministic cloud fixture.
mkdir -p /data /run/s6/container_environment
source /usr/lib/bashio/bashio.sh
cat > /data/options.json <<'JSON'
{"email":"test@example.invalid","password":"test-only","mqtt_host":"authbroker","mqtt_port":1883,"mqtt_username":"bridge-user","mqtt_password":"wrong-password","mqtt_tls":false,"poll_interval":5,"base_topic":"vicofailure","log_level":"info","bootstrap_history":false,"region":"us","api_base_override":"https://cloud.invalid"}
JSON
jq -nc --argjson ts "$(date +%s)" '[{serialNumber:"BirdCam",traceId:"retryable",timestamp:($ts-1),eventType:"bird",birdName:"Robin"}]' > /tmp/cloud-events
: > /tmp/cloud-calls
cat > /tmp/fake-vico-cli <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> /tmp/cloud-calls
if [ "$1" = devices ]; then
  echo '[{"serialNumber":"BirdCam","deviceName":"Feeder","batteryLevel":80}]'
else
  cat /tmp/cloud-events
fi
SH
chmod +x /tmp/fake-vico-cli
printf '%s' /tmp/fake-vico-cli > /run/s6/container_environment/VICO_CLI
# Confirm broker readiness with the valid fixture credentials first.
for attempt in {1..10}; do
  if mosquitto_pub -h authbroker -u bridge-user -P 'test password with spaces' -t ready -m ready 2>/dev/null; then break; fi
  sleep 1
done
mosquitto_pub -h authbroker -u bridge-user -P 'test password with spaces' -t ready -m ready
bashio::cache.set addons.self.options.config "$(cat /data/options.json)"
bridge_pid=""
cleanup() {
  if [ -n "$bridge_pid" ]; then
    kill -TERM "$bridge_pid" 2>/dev/null || true
    wait "$bridge_pid" 2>/dev/null || true
  fi
}
trap cleanup EXIT
/run.sh > /tmp/bridge-rejected.log 2>&1 &
bridge_pid=$!
for attempt in {1..35}; do
  if ! kill -0 "$bridge_pid" 2>/dev/null; then
    cat /tmp/bridge-rejected.log
    echo 'Bridge exited after rejected MQTT credentials.' >&2
    exit 1
  fi
  calls=$(grep -c '^devices ' /tmp/cloud-calls || true)
  if [ "$calls" -ge 2 ]; then break; fi
  sleep 1
done
[ "$(grep -c '^devices ' /tmp/cloud-calls || true)" -ge 2 ]
kill -0 "$bridge_pid"
# No failed historical state may have been acknowledged.
jq -e '.latest == {} and .seen == {}' /data/delivery.json >/dev/null
kill -TERM "$bridge_pid"
wait "$bridge_pid"
bridge_pid=""
if grep -q 'unbound variable' /tmp/bridge-rejected.log; then cat /tmp/bridge-rejected.log; exit 1; fi
# Correct broker credentials and restart using the same durable ledger.
jq '.mqtt_password = "test password with spaces"' /data/options.json > /tmp/options-fixed
mv /tmp/options-fixed /data/options.json
bashio::cache.set addons.self.options.config "$(cat /data/options.json)"
/run.sh > /tmp/bridge-recovered.log 2>&1 &
bridge_pid=$!
if ! state=$(mosquitto_sub -h authbroker -u bridge-user -P 'test password with spaces' -t vicofailure/birdcam/state -C 1 -W 45); then
  cat /tmp/bridge-recovered.log
  exit 1
fi
jq -e '.traceId == "retryable" and .birdName == "Robin"' <<< "$state" >/dev/null
kill -TERM "$bridge_pid"
wait "$bridge_pid"
bridge_pid=""
[ "$(mosquitto_sub -h authbroker -u bridge-user -P 'test password with spaces' -t vicofailure/bridge/status -C 1 -W 5)" = offline ]
printf 'Rejected MQTT credentials survive repeated polls/shutdown; corrected credentials recover pending bird state.\n'
