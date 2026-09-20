# New API

| `Provider` | Ring name | Icon | Host |
|---|---|---|---|
| `.newAPI` | New API | `newapi` | whatever the reader types — there is no vendor host |

Service: [`../../Sources/Pulse/Providers/NewAPIUsageService.swift`](../../Sources/Pulse/Providers/NewAPIUsageService.swift).

**The only provider here that is somebody's own site.** [New API](https://github.com/QuantumNous/new-api) is the relay software behind most "中转站": an OpenAI-compatible gateway in front of whatever upstream models its operator has keys for. It is carried as a provider because the software keeps the account's own ledger and answers the same routes its own console reads — not because there is a vendor to name. There is no CLI, no browser session, and nothing on any Mac to detect: an address and an **access token** are typed in, and that is the whole of the setup.

## Verified against a live gateway

Probed on 2026-09-20 against a company's own New API site — its address is written here as `ai.example.cn`, and that is the only thing hidden.

```
GET {site}/api/status                  → 200, no credential
{ "data": { "quota_display_type": "USD", "quota_per_unit": 500000, "usd_exchange_rate": 7.3, … } }

GET {site}/api/subscription/self       → 401 {"code":"AUTH_UNAUTHORIZED",
GET {site}/api/user/self                        "message":"无权进行此操作，access token 无效","success":false}
```

**That `401` is the reason this provider reads with a token.** The gateway's own error message names what it wants — `access token 无效` — and it is not the `sk-…` key an editor is already configured with: measured on that site, a key that answers the relay's chat routes with a completion answers those two account routes with exactly this `401`. The console issues the token it wants from **个人设置 → 安全设置 → 访问令牌** (Personal Settings → Security → Access Tokens), and the routes answer to it as `Authorization: Bearer <token>`, which is upstream's own PAT contract; no second header is needed.

The fixtures under `Tests/PulseTests/Fixtures/newapi-*.json` are the three replies this reads: `newapi-status.json` is that live gateway's own bytes, trimmed to the three fields used; `newapi-subscription-self.json` and `newapi-user-self.json` are written to the shapes new-api marshals — `model.UserSubscription`'s own JSON tags, and the dashboard user payload — because neither route can be called without somebody's token. What they hold is quota units, and the numbers in them are a real console's card, which is what the mapping is checked against.

## The routes

```
GET {site}/api/subscription/self       Authorization: Bearer <access token>
{ "success": true, "data": { "billing_preference": "subscription_first",
    "subscriptions": [ { "subscription": { "id": 7, "status": "active",
        "amount_total": 100000000, "amount_used": 13895000,
        "last_reset_time": 1755720000, "next_reset_time": 1758384000 } } ],
    "all_subscriptions": [ … ] } }

GET {site}/api/user/self               Authorization: Bearer <access token>
{ "success": true, "data": { "quota": 50000000, "used_quota": 2500000, "request_count": 412, … } }
```

Status handling is the ordinary one: `401`/`403` → `.gatewayTokenRefused`, `429` → `.rateLimited`, anything else → `.serverError`. A reply of `200 {"success": false, …}` is a failed lookup, and `NewAPIUsageService.plans(fromSelf:)` / `wallet(fromSelf:)` return nil for it, so a missing figure is never a zero.

Four things about the replies are load-bearing, and each is a wrong number read the other way round:

- **Every money figure is in quota units.** `quota_per_unit` (500000 on that gateway) converts them, and `quota_display_type` decides what the result is printed as. Read as dollars, the `amount_total` above is $100,000,000 of allowance; it is $200.
- **The subscription states both of its own figures**, so the percentage is `amount_used / amount_total`: the gateway's arithmetic on the gateway's numbers, and nothing is inferred. The console draws its own card from the same two fields.
- **The reset is the plan's, not a calendar's.** `next_reset_time` is when the allowance turns over and `last_reset_time` is what makes the window's *length* a figure from the reply rather than a guess, so a monthly plan reads "Monthly limit" and its arc is drawn from its own period. A plan that never resets its quota has no such pair, and its subscription's `end_time` is the one date there is. A length nobody stated is not invented: `reportsLength` is false and no reset is shown.
- **Money is only ever what is left.** `amount_total − amount_used` on one route and `quota` on the other are both balances, so the card's "Credit balance" row means what it says on every path through this file.

## Which of the two routes answers

| Account state | Ring | Money |
|---|---|---|
| a subscription is running | `amount_used / amount_total`, the gateway's own reset | what is **left**, from the same two figures |
| no subscription, the reader set a budget | the wallet's spend over **that** budget, marked `of your budget` | the wallet's own `quota` |
| no subscription, no budget | none — a wallet states no ceiling, so there is nothing to draw a ring against | the wallet's own `quota` |

The wallet is read only where the subscription route came back with **an empty list**, which is a complete answer rather than a fault: the account has no plan running, and a prepaid balance is the whole story. A wallet's ledger only grows, so the row it draws has no reset and no length, and the seconds on it exist only to sort it.

A denominator the reader typed is theirs, so it carries every promise an inferred percentage carries: `estimate` is set, `--json` says `estimated`, and the row reads "Spend limit · of your budget". A budget that is absent, zero, negative, infinite or NaN draws **nothing**: `Double("inf")` is greater than zero, an infinite denominator makes the fraction NaN, `min`/`max` propagate NaN rather than clamping it, and `Int(_:)` traps on it — which, persisted, crashed the panel on every launch the first time DeepSeek shipped that bug.

A plan can also be **overspent** — the wallet behind it pays the difference — so a fraction past 100% is reported rather than clamped. It is not called spent: `isExhausted` is the provider's judgement everywhere in Pulse, `status` says whether the plan is *running* rather than whether the money is gone, and neither route here carries a verdict.

## The address

Self-hosted software, so there is no default, no directory to search, and no list to pick from: the site is entered in Settings and is the one thing about this provider that cannot be known in advance. `NewAPIUsageService.baseURL(_:)` accepts `https://host`, a bare `host`, and the `/v1` base an editor is configured with — the routes above hang off the site root, not off `/v1`. Anything that does not name a host is refused rather than guessed at, and nothing is requested until both the address and the token are filled in: a blank pane reports a missing address or a missing token by name, which is why `.gatewayAddressMissing` and `.gatewayTokenMissing` are separate cases.

## The unit

`GET /api/status` — public, no credential — carries `quota_display_type`, which is what the console itself reads to decide whether to print dollars, yuan or tokens, and `quota_per_unit` / `usd_exchange_rate` beside it. It is asked first and never allowed to fail the reading: a site that will not answer it still answers the routes that carry the figures, and the software's own `QuotaPerUnit` constant stands in so the numbers are unlabelled rather than out by five orders of magnitude. `TOKENS` deliberately maps to no currency at all: a figure is then shown as what it is rather than under a symbol nobody reported.

## What is deliberately not here

- **No per-key breakdown.** These are the account's routes; a per-token ledger needs an admin key, and Pulse will not ask anyone for one. On a shared company gateway the figures are the account's, and nothing here pretends to separate them from anybody else's usage.
- **No history, no burn rate.** A subscription states a period and a reset but no series, and the wallet's `used_quota` is cumulative, so there is nothing to draw a curve through.
- **No "keys" or "models" page.** Both exist in the console and both need an admin token.

## Credential

An **access token** pasted into Settings, kept encrypted on this Mac by `APIKeyStore`, beside the site it belongs to (`AppSettings.newAPIAddress`, `AppSettings.newAPIBudget`). It is the token the console's own Security page issues, and it is *not* the `sk-…` key the reader's editor uses — the field is labelled "Access token" for that reason, and the hint under it says where the token comes from. No console password, no admin token, no cookie, no Keychain prompt. The chooser offers the provider unchecked and with no detected hint, because nothing on a Mac names a gateway — it is found in Settings like every other provider that cannot be discovered.

The token reads money **left** on both of its routes, so [`reportsSpendableBalance`](../notifications.md) is true and the settings pane offers a "warn me below" figure. That is the one trait that differs from DeepSeek's and Command Code's handling of the same setting, and it is also what puts this provider on the five-minute refresh ceiling: the money is spent on the gateway's own servers, where nothing local moves to show it happening ([../refresh-and-data.md](../refresh-and-data.md)).

## Fork note

This page and the provider it documents ship with **the fork**, not upstream. The ring, the settings rows and the tests are all additions on top of Pulse 1.3.0; the app's bundle id and Sparkle feed are this fork's own for the same reason, so that upstream's releases cannot replace a build carrying this provider.
