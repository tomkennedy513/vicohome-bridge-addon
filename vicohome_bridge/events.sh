# Event delivery helpers for run.sh. Keep all mutable state in the parent shell.
bridge_now() { date +%s; }

init_event_store() {
  mkdir -p "${DATA_DIR}" || return 1
  EVENT_STORE="${DATA_DIR}/delivery.json"
  if [ ! -f "${EVENT_STORE}" ]; then
    local now
    now=${BRIDGE_NOW:-$(bridge_now)}
    jq -n --argjson now "$now" '{version:1,cutoff:$now,seen:{},latest:{},motion:{}}' > "${EVENT_STORE}.tmp" &&
      mv "${EVENT_STORE}.tmp" "${EVENT_STORE}" || return 1
  fi
  jq -e '
    def timestamp: type == "number" and . >= 0 and isfinite;
    type == "object" and .version == 1 and (.cutoff|timestamp) and
    (.seen|type == "object" and all(.[];timestamp)) and
    (.latest|type == "object" and all(.[];type == "object" and (.ts|timestamp) and (.key|type == "string" and length > 0))) and
    (.motion|type == "object" and all(.[];timestamp)) and
    (if has("images") then
      (.images|type == "object" and all(.[];type == "object" and (.ts|timestamp) and
        (.key|type == "string" and length > 0) and (.url|type == "string" and test("^https?://")) and
        (if has("transport") then .transport == "binary" and (.content_type|type == "string" and startswith("image/")) else true end)))
     else true end) and
    (if has("history_complete") then (.history_complete|type == "boolean") else true end)
  ' "${EVENT_STORE}" >/dev/null 2>&1
}

ack_event() {
  local action="$1" deadline="$2" now="$3"
  jq --argjson action "$action" --argjson deadline "$deadline" --argjson now "$now" '
    .seen |= with_entries(select(.value >= $now - 518400)) |
    if $action.history then . else .seen[$action.key] = $action.ts end |
    if $action.state then .latest[$action.camera] = {ts:$action.ts,key:$action.key} else . end |
    if $deadline > 0 then .motion[$action.camera] = $deadline else . end
  ' "$EVENT_STORE" > "${EVENT_STORE}.tmp" && mv "${EVENT_STORE}.tmp" "$EVENT_STORE"
}

process_events() {
  local json="$1" mode="${2:-live}" now actions action camera safe_id event history state ts deadline kind
  now=${BRIDGE_NOW:-$(bridge_now)}
  if ! actions=$(printf '%s' "$json" | jq -c --slurpfile ledger "$EVENT_STORE" \
      --argjson now "$now" --arg mode "$mode" -f "${BRIDGE_LIB_DIR}/events.jq"); then
    bashio::log.warning "Invalid event response; retrying next poll."
    return 0
  fi
  while IFS= read -r action; do
    [ -z "$action" ] && continue
    camera=$(jq -r '.camera' <<< "$action")
    safe_id=$(sanitize_id "$camera")
    event=$(jq -c '.event' <<< "$action")
    history=$(jq -r '.history' <<< "$action")
    state=$(jq -r '.state' <<< "$action")
    ts=$(jq -r '.ts|floor' <<< "$action")
    ensure_discovery_published "$camera" "$(jq -r '.deviceName // .cameraName // empty' <<< "$event")" || break
    # Non-retained event stream. Stop on failure so newer state never overtakes retries.
    if [ "$history" != true ]; then
      mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/events" -m "$event" -q 1 || break
    fi
    if [ "$state" = true ]; then
      mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/state" -m "$event" -q 1 -r || break
    fi
    deadline=0
    kind=$(jq -r '.eventType // "unknown" | if type=="string" then ascii_downcase else "unknown" end' <<< "$event")
    if [ "$history" != true ] && [ "$ts" -ge "$((now - 120))" ]; then
      case "$kind" in
        motion|person|human|bird)
          mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/motion" -m ON -q 1 || break
          deadline=$((now + 5)) ;;
      esac
    fi
    if ! ack_event "$action" "$deadline" "$now"; then
      bashio::log.warning "Could not persist event acknowledgement; retrying next poll."
      break
    fi
  done <<< "$actions"
  return 0
}

download_event_image() {
  printf '%s' "$1" | "${VICO_CLI:-/usr/local/bin/vico-cli}" images fetch --output "$2" 2>/tmp/vico_image_error.log
}

# Images have their own checkpoint: a seen event may have a newly signed URL,
# and upgrades can seed images without replaying event-stream/motion messages.
publish_latest_images() {
  local json="$1" now images image camera safe_id image_file metadata content_type
  now=${BRIDGE_NOW:-$(bridge_now)}
  if ! images=$(printf '%s' "$json" | jq -c --slurpfile ledger "$EVENT_STORE" \
      --argjson now "$now" --arg mode images -f "${BRIDGE_LIB_DIR}/events.jq"); then
    bashio::log.warning "Invalid image event response; retrying next poll."
    return 0
  fi
  while IFS= read -r image; do
    [ -z "$image" ] && continue
    camera=$(jq -r '.camera' <<< "$image")
    safe_id=$(sanitize_id "$camera")
    image_file="${DATA_DIR}/latest_image_pending_${safe_id}"
    if ! metadata=$(download_event_image "$(jq -r '.url' <<< "$image")" "$image_file"); then
      bashio::log.warning "Image download failed for ${safe_id}; retrying next poll. $(head -n 1 /tmp/vico_image_error.log 2>/dev/null || true)"
      rm -f "$image_file"
      continue
    fi
    if ! content_type=$(jq -er '.content_type | select(type == "string" and startswith("image/"))' <<< "$metadata"); then
      bashio::log.warning "Image download did not return valid metadata for ${safe_id}."
      rm -f "$image_file"
      continue
    fi
    if ! ensure_discovery_published "$camera" "$(jq -r '.event.deviceName // .event.cameraName // empty' <<< "$image")" "$content_type"; then
      rm -f "$image_file"
      break
    fi
    if ! mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/image" -f "$image_file" -q 1 -r; then
      bashio::log.warning "Image publication failed for ${safe_id}; retrying next poll."
      rm -f "$image_file"
      break
    fi
    rm -f "$image_file"
    # Keep the companion URL topic for existing consumers; HA uses the bytes.
    if ! mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/image/url" -m "$(jq -r '.url' <<< "$image")" -q 1 -r; then
      bashio::log.warning "Image URL publication failed for ${safe_id}; retrying next poll."
      break
    fi
    if ! jq --argjson image "$image" --arg content_type "$content_type" '.images[$image.camera] = (($image|{ts,key,url}) + {transport:"binary",content_type:$content_type})' "$EVENT_STORE" > "${EVENT_STORE}.tmp" ||
        ! mv "${EVENT_STORE}.tmp" "$EVENT_STORE"; then
      bashio::log.warning "Could not persist image acknowledgement; retrying next poll."
      break
    fi
  done <<< "$images"
  return 0
}

reset_motion() {
  local force="${1:-false}" now camera safe_id
  now=${BRIDGE_NOW:-$(bridge_now)}
  while IFS= read -r camera; do
    [ -z "$camera" ] && continue
    safe_id=$(sanitize_id "$camera")
    if mqtt_publish "${MQTT_ARGS[@]}" -t "${BASE_TOPIC}/${safe_id}/motion" -m OFF -q 1 -r; then
      jq --arg camera "$camera" 'del(.motion[$camera])' "$EVENT_STORE" > "${EVENT_STORE}.tmp" &&
        mv "${EVENT_STORE}.tmp" "$EVENT_STORE" || return 1
    fi
  done < <(jq -r --argjson now "$now" --argjson force "$force" '.motion|to_entries[]|select($force or .value <= $now)|.key' "$EVENT_STORE")
}

fetch_events() {
  local mode="${1:-live}" now start end output
  local args=(events list --format json)
  if [ "$mode" = history ]; then
    now=${BRIDGE_NOW:-$(bridge_now)}
    # jq uses UTC RFC3339, accepted by the bundled CLI on Linux and macOS.
    start=$(jq -nr --argjson t "$((now - 432000))" '$t|todateiso8601')
    end=$(jq -nr --argjson t "$now" '$t|todateiso8601')
    args+=(--startTime "$start" --endTime "$end")
  fi
  if ! output=$("${VICO_CLI:-/usr/local/bin/vico-cli}" "${args[@]}" 2> /tmp/vico_events_error.log); then
    bashio::log.warning "Event request failed; retrying next poll."
    return 0
  fi
  if ! printf '%s' "$output" | jq -e 'type == "array"' >/dev/null 2>&1; then
    bashio::log.warning "Event request did not return a JSON array; retrying next poll."
    return 0
  fi
  process_events "$output" "$mode"
  publish_latest_images "$output"
  if [ "$mode" = history ]; then
    local remaining remaining_images
    remaining=$(printf '%s' "$output" | jq -c --slurpfile ledger "$EVENT_STORE" --argjson now "${BRIDGE_NOW:-$(bridge_now)}" --arg mode history -f "${BRIDGE_LIB_DIR}/events.jq") || return 0
    remaining_images=$(printf '%s' "$output" | jq -c --slurpfile ledger "$EVENT_STORE" --argjson now "${BRIDGE_NOW:-$(bridge_now)}" --arg mode images -f "${BRIDGE_LIB_DIR}/events.jq") || return 0
    if [ -z "$remaining" ] && [ -z "$remaining_images" ]; then
      jq '.history_complete = true' "$EVENT_STORE" > "${EVENT_STORE}.tmp" && mv "${EVENT_STORE}.tmp" "$EVENT_STORE"
    fi
  fi
  if [ "$mode" = live ] && [ "$BOOTSTRAP_HISTORY" = true ] && [ "$(jq -r '.history_complete // false' "$EVENT_STORE")" != true ] && [ "$(jq length <<< "$output")" = 0 ]; then
    fetch_events history
  fi
}
