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
  "exhausted": []                  // profile ids currently rate-limited out
}
```

- `profileOrder` is the user's configured priority — the menu bar and dropdown
  keep this order (stable, intentional, not alphabetical).
- `exhausted` marks profiles Meridian is currently routing around → show an
  explicit badge; this is stronger information than any single window's %.
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
