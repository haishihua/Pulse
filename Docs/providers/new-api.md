# New API

| `Provider` | Ring name | Icon | Host |
|---|---|---|---|
| `.newAPI` | New API | `newapi` | whatever the reader types — there is no vendor host |

Service: [`../../Sources/Pulse/Providers/NewAPIUsageService.swift`](../../Sources/Pulse/Providers/NewAPIUsageService.swift).

**The only provider here that is somebody's own site.** [New API](https://github.com/QuantumNous/new-api) is the relay software behind most "中转站": an OpenAI-compatible gateway in front of whatever upstream models its operator has keys for. It is carried as a provider because the software keeps its own ledger and answers the same two routes its own console reads — not because there is a vendor to name. There is no CLI, no browser session, and nothing on any Mac to detect: an address is typed in, and that is the whole of the setup.

## Verified against a live gateway

Probed on 2026-09-20 against a company's own New API site — its address is written here as `ai.example.cn`, and that is the only thing hidden; New API `9ad745636`, behind Tengine. `/api/status` answers unauthenticated and names the display unit; both billing routes answer `401` without a key, which is how they are known to exist and to be credential-gated. The fixtures under `Tests/PulseTests/Fixtures/newapi-*.json` are the bytes a live key returned, kept verbatim — including the sentinel below, which is the whole reason this service has two modes. `newapi-subscription-stated.json` is the same shape with a ceiling that is a real figure, because the live key is unlimited and exercises only the other case.

## The routes

Both are registered by `router/dashboard.go` in New API's own source, both wear OpenAI's dashboard names, and both take the same `sk-…` key an editor is already configured with.

```
GET {site}/v1/dashboard/billing/subscription      Authorization: Bearer <sk-…>
{ "object": "billing_subscription", "has_payment_method": true,
  "soft_limit_usd": 100000000, "hard_limit_usd": 100000000,
  "system_hard_limit_usd": 100000000, "access_until": 0 }

GET {site}/v1/dashboard/billing/usage             Authorization: Bearer <sk-…>
{ "object": "list", "total_usage": 710014.4736 }
```

Status handling is the ordinary one: `401`/`403` → `.apiKeyRefused`, `429` → `.rateLimited`, anything else → `.serverError`.

Four things about the reply are load-bearing, and each is a wrong ring read the other way round:

- **`hard_limit_usd` is the whole allowance**, remaining plus spent. The percentage is `total_usage / 100 / hard_limit_usd`, and the money left is the difference. Read as a balance, a healthy account draws a full ring.
- **`total_usage` is in cents.** `710014.4736` is $7,100.14 spent, not seven hundred thousand. Measured: adding `?start_date=…&end_date=…` returns the same figure as no parameters at all, so the dates are ignored and this is a lifetime ledger rather than a period. There is therefore no window here, no reset, and nothing to chart.
- **`100000000` is not a limit.** A key issued with `unlimited_quota` comes back with all three `*_limit_usd` fields forced to exactly that figure — which is how a company-issued key usually reads. A ring drawn against it sits at 0% for ever, so it is treated as *no ceiling reported*.
- **A refusal can arrive as HTTP 200.** These handlers answer `200 {"error":{…}}` when the account lookup fails, so a missing figure is a failed read and never a zero.

## The address

Self-hosted software, so there is no default, no directory to search, and no list to pick from: the site is entered in Settings and is the one thing about this provider that cannot be known in advance. `NewAPIUsageService.baseURL(_:)` accepts `https://host`, a bare `host`, and the `/v1` base an editor is configured with — the routes above hang off the site root, not off `/v1`. Anything that does not name a host is refused rather than guessed at, and nothing is requested until either field is filled in.

## Most of these keys have no ceiling, so the ring needs a denominator

Where the gateway states an allowance, the percentage is **its own arithmetic on its own two figures** and nothing is inferred — the same rule as every other provider here. Where it states none, there are exactly two honest outcomes, and `NewAPIUsageService.windows` has both:

| Gateway says | Ring | Money |
|---|---|---|
| `hard_limit_usd` is a real figure | `spent / ceiling`, no estimate | what is **left**, as a balance |
| the sentinel, and the reader set a budget | `spent / budget`, marked `of your budget` | what is **gone**, as a spend |
| the sentinel, and no budget | none — the card says so, and points at the setting | nothing |

A spend is not a balance, which is why `ProviderUsage.creditIsSpent` exists: every provider that reported money before this one reported what was *left*, and `Spent so far` / `Credit balance` are two different sentences about two different numbers. The row is drawn from the reading rather than chosen by the view.

A denominator the reader typed is theirs, so it carries every promise an inferred percentage carries: `estimate` is set, `--json` says `estimated`, and the row reads "Spend limit · of your budget". There is no reset and no length — a ledger has neither — and `reportsLength` is false so nothing divides by the seconds, which exist only to sort the row.

A budget that is absent, zero, negative, infinite or NaN draws **nothing**. `Double("inf")` is greater than zero, an infinite denominator makes the fraction NaN, `min`/`max` propagate NaN rather than clamping it, and `Int(_:)` traps on it — which, persisted, crashed the panel on every launch the first time DeepSeek shipped that bug.

## The unit

`GET /api/status` — public, no credential — carries `quota_display_type`, which is what the console itself reads to decide whether to print dollars, yuan or tokens. It is the only reason money is printed under a currency symbol rather than as a bare number, and `TOKENS` deliberately maps to no currency at all: a figure is then shown as what it is rather than under a symbol nobody reported. A status route that fails to answer costs nothing but the symbol.

## What is deliberately not here

- **No per-key breakdown.** A key issued with a ceiling reports that key's own ledger; one issued without reports the *account's*, because there is no token-scoped figure on this route (that needs an admin token, and Pulse will not ask anyone for one). A shared company key therefore shows what the account has spent, and nothing here pretends to separate it from anybody else's usage.
- **No history, no burn rate.** The spend is cumulative and the dates are ignored, so there is no per-period series to draw and no window for `BurnRate` to forecast: `resetsAt` is nil and `reportsLength` false.
- **No "spent" verdict.** `isExhausted` is the provider's judgement everywhere in Pulse, and these two routes do not carry one — new-api's verdicts live on the token list, which needs an admin key. A limit running past 100% is drawn as over 100% and not called spent. A key that has genuinely run out shows up as a lower spend, not as a failure.
- **No "warn me below" line.** `reportsSpendableBalance` is false, so no low-balance alert is offered: the figure is a spend, and money left exists only where the gateway states a ceiling of its own. A control that can never fire is worse than one that is not there. The cost of that flag's pair — `spendingIsWatchedLocally` — is the *idle* cadence only: with nothing local moving, a refresh is left to the half-hour ceiling instead of the five-minute one, and a hover or a figure that moved brings it back to two minutes.

## Credential

A key pasted into Settings, kept encrypted on this Mac by `APIKeyStore`, beside the site it belongs to (`AppSettings.newAPIAddress`, `AppSettings.newAPIBudget`). The key is the same `sk-…` the reader's editor uses; no console password, no admin token, no cookie, no Keychain prompt. The chooser offers the provider unchecked and with no detected hint, because nothing on a Mac names a gateway — it is found in Settings like every other provider that cannot be discovered.

## Fork note

This page and the provider it documents ship with **the fork**, not upstream. The ring, the settings rows and the tests are all additions on top of Pulse 1.3.0; the app's bundle id and Sparkle feed are this fork's own for the same reason, so that upstream's releases cannot replace a build carrying this provider.
