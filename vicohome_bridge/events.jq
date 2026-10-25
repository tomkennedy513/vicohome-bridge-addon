# Normalize once per batch; never depend on API response order or signed URLs for identity.
def epoch:
  if type == "number" then (if . > 100000000000 then ./1000 else . end)
  elif type == "string" then
    . as $timestamp |
    (try tonumber catch (try ($timestamp | sub(" ";"T") | if endswith("Z") or test("[+-][0-9]{2}:[0-9]{2}$") then . else .+"Z" end | fromdateiso8601) catch null))
  else null end;
def camera: .serialNumber // .deviceId // .device_id // .camera_id // .camera.uuid // .cameraId // empty;
def image_url:
  [.imageUrl,.keyShotUrl] | .[] | select(type == "string")
  | select(test("^https?://[^/[:space:]]+[^[:space:]]*$"));
def etype: .eventType // .type // .event_type // "unknown";
$ledger[0] as $store |
if type != "array" then error("expected event array") else . end
| [ .[] | select(type == "object")
    | . as $event | (camera | select(type == "string" and length > 0)) as $camera
    | (.timestamp | epoch) as $ts
    | select($ts != null and $ts >= $now - 518400 and $ts <= $now + 300)
    | {camera:$camera, ts:$ts, event:($event + {eventType:etype}),
       key:([$camera, (([.traceId,.eventId,.id] | map(select(. != null and . != "")) | .[0]) // [$ts,etype])] | tojson)} ]
| unique_by(.key) | sort_by(.ts,.key)
| . as $all
| if $mode == "images" then
    [ $all[] | . + {url:(.event | [image_url] | .[0])} | select(.url != null) ]
    | group_by(.camera) | map(max_by(.ts,.key))
    | map(select(
        [.ts,.key] > [($store.images[.camera].ts // 0),($store.images[.camera].key // "")]
        or ([.ts,.key] == [($store.images[.camera].ts // 0),($store.images[.camera].key // "")]
            and .url != $store.images[.camera].url)))
    | sort_by(.ts,.key) | .[:60] | .[]
  else
    ([ $all[] | select(.ts <= $store.cutoff or $mode == "history") ]
     | group_by(.camera) | map(max_by(.ts,.key))
     | map(select([.ts,.key] > [($store.latest[.camera].ts // 0),($store.latest[.camera].key // "")]))
     | map(. + {history:true, state:true})) as $history
    | ([ $all[] | select(.ts > $store.cutoff and $mode != "history")
       | select($store.seen[.key] == null)
       | . + {history:false, state:([.ts,.key] >= [($store.latest[.camera].ts // 0),($store.latest[.camera].key // "")])} ]) as $live
    | ($history + $live) | sort_by(.ts,.key) | .[:60] | .[]
  end
