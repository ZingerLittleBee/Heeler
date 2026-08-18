# herdr Push Relay

The developer-hosted, stateless forwarder for Agent Notifications (ADR 0008).
The plugin's notify hook on a Host encrypts a notification payload with the
per-host Notification Key and POSTs it here. The relay forwards ciphertext
verbatim through APNs or FCM using only deploy-time provider credentials, then
relays the provider's verdict back. It is a dumb pipe on purpose:

- **No message state**: no accounts, database, queue, message history, or
  retries (the plugin retries). A relay compromise can expose deploy-time
  provider credentials and in-flight device tokens, source IPs, APNs
  environments when used, collapse identifiers, request metadata, and
  ciphertext. It still cannot decrypt notification content because it never
  receives Notification Keys.
- **Production origin**: the official app and plugin default to
  `https://heeler-apns.bybee.dev`. Both still accept a custom relay base URL
  for self-built apps whose provider credentials are authorized for the
  selected app.
- **What crosses it**: the request carries a provider, device token,
  provider-specific APNs environment when applicable, ciphertext, and an
  opaque collapse identifier. The notification envelope itself is
  provider-neutral and remains opaque to the relay. The relay also observes
  the source IP, request timing, frequency, and size.

Runs as a Cloudflare Worker-style fetch handler with zero runtime
dependencies (WebCrypto + fetch), which is also why the tests run under
plain Node.

## API

### `POST /push`

Request body (JSON, ≤ 8 KB):

| Field      | Type   | Required | Meaning |
| ---------- | ------ | -------- | ------- |
| `provider` | string | no       | `apns` or `fcm`. Omitted means `apns`, so the v1 request remains valid and byte-compatible. |
| `token`    | string | yes      | APNs: lowercase hexadecimal device token (16–200 chars). FCM: opaque, non-empty registration token. |
| `env`      | string | APNs only | `production` or `sandbox` — which APNs environment the token belongs to. FCM requests must omit it. |
| `envelope` | string | yes      | Provider-neutral notification envelope (see `plugin/README.md`), forwarded as-is. Opaque to the relay. |
| `collapse` | string | no       | Opaque collapse key, ≤ 64 bytes; APNs receives it as `apns-collapse-id`, FCM as `android.collapse_key`. |

APNs remains the v1 path: the relay wraps the envelope in a
`mutable-content: 1` alert push with a generic fallback title/body and enforces
Apple's 4 KB alert-payload cap. FCM receives a data-only HTTP v1 message:

```json
{"message":{"token":"<opaque token>","data":{"envelope":"<exact envelope>"},"android":{"priority":"high","collapse_key":"<collapse when present>"}}}
```

The FCM data payload also has a 4 KB cap; the relay applies that cap before it
contacts either provider.

### Responses

| Status | Body | Meaning |
| ------ | ---- | ------- |
| 200 | `{"apnsId": "..."}` or `{"fcmName": "..."}` | Provider accepted the push. |
| 400 | `{"error": "bad_json" \| "bad_provider" \| "bad_token" \| "bad_env" \| "bad_envelope" \| "bad_collapse"}` | Request rejected by the relay before contacting a provider. |
| 404 / 405 | `{"error": ...}` | Wrong path / method (`allow: POST`). |
| 413 | `{"error": "request_too_large" \| "payload_too_large"}` | Request body over 8 KB, or the final provider payload over its 4 KB cap. |
| 429 | `{"error": "rate_limited"}` + `retry-after` | Per-IP or per-token limit hit (defaults 120 and 60 per minute; overridable via vars). |
| 500 | `{"error": "relay_misconfigured"}` | Missing or malformed deploy config for the requested provider. |
| 502 | `{"error": "apns_unreachable" \| "fcm_unreachable"}` | Could not reach the requested provider or FCM OAuth endpoint. |
| other | `{"reason": "..."}` | Provider verdict relayed with its status. APNs `410 Unregistered` is unchanged; FCM's typed `UNREGISTERED` verdict (HTTP 404) becomes the equivalent `410 {"reason":"Unregistered"}` so the plugin prunes it identically. |

Relay-origin errors always use the `error` key; relayed provider verdicts use
`reason`, so callers can tell the two apart on overlapping status codes.

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
| `FCM_PROJECT_ID` | no | Firebase/Google Cloud project id in the FCM HTTP v1 endpoint. |
| `FCM_SA_CLIENT_EMAIL` | no | Service-account `client_email`, the JWT `iss`. |
| `FCM_SA_PRIVATE_KEY_PKCS8` | **yes** | PEM contents of the service-account JSON key's `private_key` field. Deploy-time secret — never commit it or put it in `[vars]`. |
| `RATE_LIMIT_IP_PER_MIN` | no | Optional per-IP limit override. |
| `RATE_LIMIT_TOKEN_PER_MIN` | no | Optional per-token limit override. |

APNs and FCM are independently optional: a request only requires the selected
provider's variables. APNs JWTs are cached for ~50 minutes per worker
instance. FCM service-account assertions are exchanged for and reuse a
short-lived OAuth token, refreshed one minute before the returned expiry.

## Tests

```bash
npm test
```

Node's built-in test runner, no dependencies. The boundary suite drives the
fetch handler exactly as the platform would and stubs APNs, FCM, and the
Google OAuth endpoint at the network edge. Unit suites cover both JWT signing
and token-cache clocks plus rate-limit windows.

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

### FCM setup

Enable the Firebase Cloud Messaging API for `FCM_PROJECT_ID`, then create a
service-account key with permission to send for that project. The
[FCM HTTP v1 guide](https://firebase.google.com/docs/cloud-messaging/send/v1-api)
documents the required `firebase.messaging` OAuth scope and endpoint; the
[Google service-account guide](https://developers.google.com/identity/protocols/oauth2/service-account)
documents the RS256 JWT exchange. Set `FCM_PROJECT_ID` and
`FCM_SA_CLIENT_EMAIL` as deploy-time vars, then run
`npx wrangler secret put FCM_SA_PRIVATE_KEY_PKCS8` and paste the PEM value of
the downloaded service-account JSON's `private_key` field. Do not commit the
downloaded JSON or add its private key to `[vars]`.

For local development `npx wrangler dev` works with the same vars in a
`.dev.vars` file (gitignored — APNs and FCM private keys stay out of the repo).
