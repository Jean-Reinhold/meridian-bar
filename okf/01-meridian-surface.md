# The Meridian API surface

Everything below was captured from a live Meridian instance (*verified
2026-08-06, Meridian 1.60.0*, default bind `127.0.0.1:3456`). MeridianBar is a
pure client of this surface: local HTTP, no auth (Meridian is loopback-only),
JSON in both directions.

## Endpoints we consume

| Endpoint | Purpose | Poll cadence |
|---|---|---|
| `GET /v1/usage/quota/all` | Per-profile quota windows + extra usage. **The core poll.** | 60 s + on menu open |
| `GET /profiles/list` | Profile identity: active, routing, exhausted, auth status | 60 s + on menu open |
| `GET /health` | Proxy liveness, version, active-profile token state | 60 s |
| `POST /profiles/active` | Switch the active profile (menu action) | on demand |
| `GET /model-router/routes` | Optional: which profile serves Fable requests (model router only) | 60 s |

## `GET /v1/usage/quota/all`

```jsonc
{
  "profiles": [
    {
      "id": "jeanpaul",
      "error": null,            // null | "no_token" | "not_oauth" | ...
      "fetchedAt": 1786035002549, // epoch ms — data age, NOT our poll time
      "windows": [
        { "type": "five_hour",       "utilization": 0.00, "resetsAt": 1786040400453 },
        { "type": "seven_day",       "utilization": 0.91, "resetsAt": 1786064400453 },
        { "type": "seven_day_fable", "utilization": 1.00, "resetsAt": 1786064400453 }
      ],
      "extraUsage": { "isEnabled": false /* , monthlyLimit, usedCredits, utilization, currency */ }
    }
  ]
}
```

Semantics that drive the UI:

- `utilization` is 0–1, may reach exactly 1.0 (window exhausted / rejected).
- `resetsAt` is epoch ms; countdown = `resetsAt - now`, "resetting…" when ≤ 0.
- `fetchedAt` is when *Meridian* last refreshed the quota from Anthropic —
  surface it as data age ("updated 4m ago"). Meridian caches; two consecutive
  polls can return identical `fetchedAt`.
- `error: "no_token"` → profile needs `claude login`; `"not_oauth"` →
  API-key profile, no OAuth quota exists — hide usage, keep identity.
- Windows without a numeric `utilization` are skipped (Meridian's own UI
  filters the same way).

### Window types (open set)

Known labels, from Meridian's `WINDOW_LABELS` map (*verified 1.60.0*):

| type | label |
|---|---|
| `five_hour` | 5h |
| `seven_day` | 7d |
| `seven_day_opus` | 7d Opus |
| `seven_day_sonnet` | 7d Sonnet |
| `seven_day_fable` | 7d Fable |
| `seven_day_oauth_apps` | 7d Apps |
| `seven_day_cowork` | 7d Cowork |
| `seven_day_omelette` | 7d Omelette |

**Compatibility rule:** the set is open — Anthropic adds windows over time.
Unknown types MUST render via the fallback (`split('_')` → title-case join),
never break or hide.

## `GET /profiles/list`

```jsonc
{
  "profiles": [
    {
      "id": "jeanpaul",
      "type": "claude-max",
      "isActive": true,
      "email": "redacted@example.com",
      "subscriptionType": "max",
      "loggedIn": true,
      "lastCheckedAt": 1786034996448,
      "lastSuccessAt": 1786034996448
    }
  ],
  "activeProfile": "jeanpaul",
  "routing": "priority",          // sticky-session routing mode
  "profileOrder": ["jean_reinhold", "jeanpaul", "jeanpnr"],
  "exhausted": [                   // profiles currently rate-limited out
    {"id": "jean_reinhold", "until": 1786122000000, "reason": "rate_limit_error"}
  ]
}
```

- `profileOrder` is the user's configured priority — the menu bar and dropdown
  keep this order (stable, intentional, not alphabetical).
- `exhausted` marks profiles Meridian is currently routing around → show an
  explicit badge; this is stronger information than any single window's %.
  Entries are objects (`id`, `until` epoch ms, `reason`) — verified live
  2026-08-07 against 1.60.0. Captures ≤2026-08-06 sent bare id strings;
  decoding must accept both shapes.
- `loggedIn: false` → warning badge + the `meridian profile login <id>` hint.

## `GET /health`

```jsonc
{
  "status": "healthy",             // healthy | degraded | ...
  "version": "1.60.0",
  "auth": {
    "loggedIn": true,
    "email": "redacted@example.com",
    "subscriptionType": "max",
    "refreshTokenExpiresAt": 1788596877976,
    "daysUntilRenewal": 30,
    "renewalRequiredSoon": false   // true → surface a renewal warning
  },
  "mode": "internal",
  "plugin": { "opencode": "not-configured" }
}
```

## `POST /profiles/active`

Body `{"profile": "<id>"}` → `{"success": true}`. Takes effect immediately,
no proxy restart. Refresh `profiles/list` right after to update badges.

## `PUT /settings/api/routing` (*verified live 2026-08-07, 1.60.0*)

Body `{"profileOrder": ["<id>", ...]}` → `{"success": true}`. Reorders the
priority pool; takes effect immediately (read per request), persists to
`~/.config/meridian/settings.json`, no restart. Unknown ids → 400.
`GET /settings/api/routing` returns the effective `{routing, profileOrder}`.

**Important:** under `routing: "priority"`, chat dispatch walks
`profileOrder` only — the `activeProfile` switch does NOT steer chat
traffic. Rotation (failover down the order) fires only when a response is
classified `rate_limit_error`; per-session assignments are sticky
(in-memory, cleared on restart).

## `GET /model-router/routes` (optional, model router only)

A local model router can sit in front of Meridian at the same base URL. It
proxies every Meridian path unchanged and adds this endpoint. It pins Fable
requests to one profile and leaves other requests on Meridian's active
profile.

```jsonc
{
  "fable": "<profile id>",   // serves Fable requests; null when no decision
  "general": "<profile id>", // last made active for other requests; null when none
  "decidedAt": 1794647062006 // epoch ms of the last decision; null when none
}
```

Plain Meridian answers 404 with `{"error":{"type":"not_found",...}}`
(*verified live 2026-11-14, Meridian 1.88.0*). The router on port 3457
answered 200 with
`{"fable":"jean_reinhold","general":"jean_reinhold","decidedAt":1794647286053}`
(*verified live 2026-11-14*).

MeridianBar polls it alongside the core requests and treats any failure as
"no route information". It never counts toward the offline state. When
`fable` is set, that profile's card gets a FABLE badge and its bar segment
gets an `F<percent>%` suffix from its `seven_day_fable` window. `general`
and `decidedAt` are decoded but not shown.

## Thresholds (shared with Meridian's UI)

Meridian's dashboard classifies utilization as: **ok < 0.60 ≤ warn < 0.85 ≤
high**. MeridianBar uses the identical thresholds so both UIs always agree
(*verified: `classifyUtilization` in Meridian 1.60.0 page source*).

## Failure modes

| Condition | Detection | Required behavior |
|---|---|---|
| Meridian not running | connection refused / timeout on any poll | offline state: keep last data grayed, label shows offline marker, keep polling at normal cadence |
| Meridian restarting | intermittent 5xx | same as offline; recover silently on next success |
| Endpoint missing (older Meridian) | 404 on `/v1/usage/quota/all` | identity-only mode: show profiles without usage, footer notes "Meridian ≥1.5x required for usage" `[unverified: exact minimum version]` |
| Partial data | per-profile `error` set | per-profile degraded card, others unaffected |

## Non-goals at this layer

- No scraping of `~/.config/meridian/telemetry.db` in v1 — the HTTP surface is
  the contract; the DB schema is internal to Meridian and may change. (F14
  in `05-features.md` revisits this for history sparklines, behind the same
  caveat.)
- No talking to Anthropic directly — Meridian owns auth; we never see tokens.

## Codex and account management, verified 2026-09-07

The owner requested local Codex consumption and account management from the bar.
This extends the original read-only, loopback-only scope.

- Live Meridian 1.60.0 still returns the documented health and profile fields.
- Installed Meridian 1.60.0 implements `profile add <name>`,
  `profile login <name>`, and `profile remove <name>`. Names accept letters,
  digits, hyphens, and underscores. Add and login invoke `claude auth login`
  with the profile's `CLAUDE_CONFIG_DIR`. Add can first prompt to import the
  default Claude login. Removal updates the profile registry and deletes
  Meridian-owned profile directories. The proxy reloads profile changes.
- Installed Claude supports `auth login`, `auth logout`, and `auth status`.
- Installed Codex supports `login`, `login status`, and `logout`.
  The current file-based login is in `~/.codex/auth.json`, with `auth_mode`,
  `tokens`, and `last_refresh`. The token object has `id_token`,
  `access_token`, `refresh_token`, and `account_id`.
- A live authenticated GET to `https://chatgpt.com/backend-api/wham/usage`
  returned HTTP 200. Authentication uses a bearer access token and
  `ChatGPT-Account-Id`. The response includes `plan_type`, `rate_limit`,
  `code_review_rate_limit`, `additional_rate_limits`, and `credits`.
  Rate-limit windows use `used_percent`, `limit_window_seconds`,
  `reset_after_seconds`, and `reset_at`. Windows may be null.

Credentials and real account values are not recorded here. Usage requests must
use the fixed ChatGPT endpoint, never a user-supplied credential destination.
Local Codex session usage is separate from account-wide quota. The UI must label
these scopes separately and must not present local token counts as billed cost.

## OMP OpenAI account pool, verified 2026-09-07

The owner wants OMP's GPT traffic to use the Codex accounts saved in the bar.
OMP (`omp` 18.1.13, `@oh-my-pi/pi-ai` 17.4.0) keeps one credential pool per
provider and load-balances requests across every `openai-codex` row.

- Store: `~/.omp/agent/agent.db` (`PI_CODING_AGENT_DIR` overrides the
  directory), table `auth_credentials` with `provider`, `credential_type`,
  `data` (JSON with `access`, `refresh`, `expires`, `email`, `accountId`),
  `disabled_cause` (NULL when active), `identity_key`. The app opens this
  file read-only and reads only `email` and `accountId`.
- Add or refresh: `omp auth-broker import <dir> --provider=openai-codex --json`
  reads CLIProxyAPI-style JSON files (`type`, `access_token`,
  `refresh_token`, `id_token`, `expired` RFC 3339, `email`, `account_id`).
  Rows are matched by identity, so re-importing an account replaces its row.
  Files without a parseable `expired` are skipped; the app derives it from
  the access token's `exp` claim.
- Clear: `omp auth-broker logout openai-codex` soft-deletes every row for the
  provider. There is no per-row removal command. Removing one account
  therefore means clear, then re-import the remaining ones, and is refused
  when the pool holds a row the app does not manage.
- Remote broker: when `auth.broker.url` is set in `~/.omp/agent/config.yml`
  (or `OMP_AUTH_BROKER_URL`), OMP ignores the local store. The app then
  reports the pool as not manageable.
- Refresh tokens are copied, not shared. After import, OMP and the Codex CLI
  refresh their own copy. Whether OpenAI invalidates the older refresh token
  after a rotation is `[unverified]`; the recovery path is "Sign in again",
  which re-imports the fresh login.

Live check 2026-09-07: the pool held one active `openai-codex` row with the
same identity as `~/.codex/auth.json`; launching the app marked it routed and
ran no import (no staging directory was created, row data unchanged).
