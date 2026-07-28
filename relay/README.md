# herdr Push Relay

The developer-hosted, stateless forwarder for Agent Notifications (ADR 0008).
The plugin's notify hook on a Host encrypts a notification payload with the
per-host Notification Key and POSTs it here; the relay signs the APNs
provider JWT with the deploy-time `.p8`, forwards the ciphertext verbatim to
Apple, and relays Apple's verdict back. It is a dumb pipe on purpose:

- **No state**: no accounts, no database, no queue, no retries (the plugin
  retries). Compromising the relay yields device tokens and ciphertext,
  never content.
- **Production origin**: the official app and plugin default to
  `https://herdr-apns.bybee.dev`. Both still accept a custom relay base URL
  for self-built apps because APNs keys are bound to the bundle id.
- **What crosses it**: device token, ciphertext, source IP. Nothing else;
  the relay never parses the envelope.

Runs as a Cloudflare Worker-style fetch handler with zero runtime
dependencies (WebCrypto + fetch), which is also why the tests run under
plain Node.

## API

### `POST /push`

Request body (JSON, ≤ 8 KB):

| Field      | Type   | Required | Meaning |
| ---------- | ------ | -------- | ------- |
| `token`    | string | yes      | APNs device token, lowercase hex (16–200 chars). |
| `env`      | string | yes      | `production` or `sandbox` — which APNs environment the token belongs to, per device entry in the registration file. |
| `envelope` | string | yes      | The notification envelope (see `plugin/README.md`), forwarded verbatim. Opaque to the relay. |
| `collapse` | string | no       | Opaque collapse key, ≤ 64 bytes; passed through as `apns-collapse-id` so a newer status replaces an older one. |

The relay wraps the envelope in a `mutable-content: 1` alert push with a
generic fallback title/body (the app's service extension rewrites them after
decrypting) and enforces Apple's 4 KB alert-payload cap before forwarding.

### Responses

| Status | Body | Meaning |
| ------ | ---- | ------- |
| 200 | `{"apnsId": "..."}` | APNs accepted the push. |
| 400 | `{"error": "bad_json" \| "bad_token" \| "bad_env" \| "bad_envelope" \| "bad_collapse"}` | Request rejected by the relay before contacting APNs. |
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
| `APNS_TOPIC` | no | The app bundle id (`apns-topic`). |
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

The production Worker is deployed at `https://herdr-apns.bybee.dev`. Its
custom domain is declared in `wrangler.toml`, keeping deploys on the canonical
origin and disabling the fallback `workers.dev` route.

1. In the Apple Developer portal, create an APNs auth key (`.p8`) for the
   team that signs the app; note the key id and team id.
2. `npx wrangler deploy` from this directory (a Cloudflare account is the
   only prerequisite; the worker has no build step).
3. Set the vars: `APNS_TEAM_ID`, `APNS_KEY_ID`, `APNS_TOPIC` (either
   uncomment them in `wrangler.toml` or set them in the dashboard).
4. `npx wrangler secret put APNS_KEY_P8` and paste the `.p8` PEM contents.
5. Smoke-test with a sandbox token:
   `curl -s -X POST https://herdr-apns.bybee.dev/push -d '{"token":"<hex>","env":"sandbox","envelope":"{}","collapse":"smoke"}'`
   — expect an APNs verdict (`200` or a relayed `400 BadDeviceToken`), not
   `relay_misconfigured`.

For local development `npx wrangler dev` works with the same vars in a
`.dev.vars` file (gitignored — the `.p8` stays out of the repo).
