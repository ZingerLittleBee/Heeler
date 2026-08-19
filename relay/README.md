# herdr Push Relay

The developer-hosted, stateless forwarder for Agent Notifications (ADR 0008)
and per-Host Live Activity updates (`docs/agents/live-activity-contract.md`).
The plugin encrypts a payload with the per-host Notification Key and POSTs it
here; the relay signs the APNs provider JWT with the deploy-time `.p8`,
forwards the ciphertext verbatim to Apple, and relays Apple's verdict back.
It is a dumb pipe on purpose:

- **No message state**: no accounts, database, queue, message history, or
  retries (the plugin retries). A relay compromise can expose the APNs
  credential and in-flight device tokens, source IPs, APNs environment,
  collapse identifiers, request metadata, and ciphertext. It still cannot
  decrypt notification content because it never receives Notification Keys.
- **Production origin**: the official app and plugin default to
  `https://heeler-apns.bybee.dev`. Both still accept a custom relay base URL
  for self-built apps whose APNs credentials are authorized for their bundle
  ID.
- **What crosses it**: the request carries the device token, APNs environment,
  ciphertext, and (on the alert path) an opaque collapse identifier. Live
  Activity requests also carry the agent **counts**, the **event**
  (`update` / `end`), and the **priority**. The relay also observes the
  source IP, request timing, frequency, and size. It never decrypts the
  envelope.

Runs as a Cloudflare Worker-style fetch handler with zero runtime
dependencies (WebCrypto + fetch), which is also why the tests run under
plain Node.

## API

### `POST /push`

Request body (JSON, ≤ 8 KB). Bodies **without** `kind` are the original
alert path and must remain byte-identical to the pre-Live-Activity relay.
`kind: "liveactivity"` selects the Live Activity path. Any other `kind`
value, or a `kind` field on an alert body, is `bad_kind`.

#### Alert path (no `kind`)

| Field      | Type   | Required | Meaning |
| ---------- | ------ | -------- | ------- |
| `token`    | string | yes      | APNs device token, lowercase hex (16–200 chars). |
| `env`      | string | yes      | `production` or `sandbox` — which APNs environment the token belongs to, per device entry in the registration file. |
| `envelope` | string | yes      | The notification envelope (see `plugin/README.md`), forwarded verbatim. Opaque to the relay. |
| `collapse` | string | no       | Opaque collapse key, ≤ 64 bytes; passed through as `apns-collapse-id` so a newer status replaces an older one. |

The relay wraps the envelope in a `mutable-content: 1` alert push with a
generic fallback title/body (the app's service extension rewrites them after
decrypting) and enforces Apple's 4 KB payload cap before forwarding.

#### Live Activity path (`kind: "liveactivity"`)

| Field            | Type    | Required | Meaning |
| ---------------- | ------- | -------- | ------- |
| `kind`           | string  | yes      | Must be `liveactivity`. |
| `token`          | string  | yes      | Per-activity APNs push token, same hex rules as the alert path. |
| `env`            | string  | yes      | `production` or `sandbox`. |
| `event`          | string  | yes      | `update` or `end`. |
| `priority`       | integer | yes      | `5` or `10`. `10` additionally requires `counts.blocked >= 1`. |
| `timestamp`      | integer | yes      | Unix seconds; must be positive and within `[now − 86400, now + 300]`. |
| `stale_date`     | integer | no       | Must be `> timestamp` when present. Sent as APNs `stale-date`. |
| `dismissal_date` | integer | no       | Allowed only when `event` is `end`. Sent as APNs `dismissal-date`. |
| `counts`         | object  | yes      | Exactly `working`, `blocked`, `done`, each an integer `0..999`. |
| `envelope`       | string  | yes      | Canonical activity-envelope JSON, forwarded without parsing. |
| `collapse`       | —       | no       | Must be **absent**. Live Activity pushes do not set `apns-collapse-id`. |

The APNs request uses `apns-push-type: liveactivity` and
`apns-topic: ${APNS_TOPIC}.push-type.liveactivity` (suffix-derived from the
existing topic; no extra config var). The body is `aps` only —
`timestamp`, `event`, `content-state: {counts, envelope}`, and the optional
dates — never `alert` or `mutable-content`. The same 4 KB payload cap
applies.

### Responses

| Status | Body | Meaning |
| ------ | ---- | ------- |
| 200 | `{"apnsId": "..."}` | APNs accepted the push. |
| 400 | `{"error": "bad_json" \| "bad_kind" \| "bad_token" \| "bad_env" \| "bad_event" \| "bad_priority" \| "bad_timestamp" \| "bad_stale_date" \| "bad_dismissal_date" \| "bad_counts" \| "bad_envelope" \| "bad_collapse"}` | Request rejected by the relay before contacting APNs. |
| 404 / 405 | `{"error": ...}` | Wrong path / method (`allow: POST`). |
| 413 | `{"error": "request_too_large" \| "payload_too_large"}` | Request body over 8 KB, or the final APNs payload would exceed 4 KB. |
| 429 | `{"error": "rate_limited"}` + `retry-after` | Per-IP or per-token limit hit (defaults 120 and 60 per minute; overridable via vars). |
| 500 | `{"error": "relay_misconfigured"}` | Missing or malformed APNs deploy config. |
| 502 | `{"error": "apns_unreachable"}` | Could not reach APNs at all. |
| other | `{"reason": "...", "timestamp"?: n}` | APNs verdict relayed as-is — same status code, Apple's `reason` string. `410` + `Unregistered` tells the plugin to prune that token. |

Relay-origin errors always use the `error` key; relayed APNs verdicts always
use `reason`, so callers can tell the two apart on overlapping status codes.

Rate limits live in per-isolate memory (the relay has no database by
design), so they are best-effort per worker instance — enough to blunt
quota-burning abuse, not a billing-grade quota.

## Configuration

| Var | Secret | Meaning |
| --- | ------ | ------- |
| `APNS_TEAM_ID` | no | Apple Developer Team ID (JWT `iss`). |
| `APNS_KEY_ID` | no | APNs auth key id (JWT `kid`). |
| `APNS_KEY_P8` | **yes** | PEM contents of the APNs auth key. Deploy-time secret — never commit a `.p8`, never put it in `[vars]`. |
| `APNS_TOPIC` | no | The app bundle id (`apns-topic`). Live Activity pushes use `${APNS_TOPIC}.push-type.liveactivity` (derived by suffix; no extra var). |
| `RATE_LIMIT_IP_PER_MIN` | no | Optional per-IP limit override. |
| `RATE_LIMIT_TOKEN_PER_MIN` | no | Optional per-token limit override. |

The signed JWT is cached for ~50 minutes per worker instance (Apple rejects
tokens older than 60 and throttles keys re-signing more often than every 20).

## Tests

```bash
npm test
```

Node's built-in test runner, no dependencies. The boundary suite drives the
fetch handler exactly as the platform would and stubs APNs at the network
edge (the outbound `fetch`); unit suites cover the JWT cache clock and the
rate-limit windows.

## Deploy

The production Worker is deployed at `https://heeler-apns.bybee.dev`. Its
custom domain is declared in `wrangler.toml`, keeping deploys on the canonical
origin and disabling the fallback `workers.dev` route. The retired
`herdr-apns.bybee.dev` still routes to the same Worker while deployed plugins
migrate off it; see the comment on that route in `wrangler.toml`.

1. In the Apple Developer portal, create an APNs auth key (`.p8`) for the
   team that signs the app; note the key id and team id.
2. `npx wrangler deploy` from this directory (a Cloudflare account is the
   only prerequisite; the worker has no build step).
3. Set the vars: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC` (either
   uncomment them in `wrangler.toml` or set them in the dashboard).
4. `npx wrangler secret put APNS_KEY_P8` and paste the `.p8` PEM contents.
5. Smoke-test with a sandbox token:
   `curl -s -X POST https://heeler-apns.bybee.dev/push -d '{"token":"<hex>","env":"sandbox","envelope":"{}","collapse":"smoke"}'`
   — expect an APNs verdict (`200` or a relayed `400 BadDeviceToken`), not
   `relay_misconfigured`.

For local development `npx wrangler dev` works with the same vars in a
`.dev.vars` file (gitignored — the `.p8` stays out of the repo).
