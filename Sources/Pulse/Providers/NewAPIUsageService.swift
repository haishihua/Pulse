import Foundation

/// A self-hosted **New API** gateway — the software most "中转站" run.
///
/// [New API](https://github.com/QuantumNous/new-api) is an OpenAI-compatible
/// relay that also keeps the account's own ledger, and it answers two of the
/// routes its own console reads. Both are registered by
/// `router/dashboard.go`'s `SetDashboardRouter`, both carry the OpenAI
/// dashboard names, and both take the same `sk-…` key the user pastes into
/// their editor — nothing has to be signed in to again.
///
/// | Call | What it holds |
/// |---|---|
/// | `GET /v1/dashboard/billing/subscription` | `hard_limit_usd` — **the whole allowance**, remaining plus spent |
/// | `GET /v1/dashboard/billing/usage` | `total_usage` — what is gone, **times 100** (OpenAI's cent convention) |
///
/// `GET /api/status` — public, no credential — names the unit those figures
/// are in, so a CNY storefront is not drawn in dollars.
///
/// Four things about this reply are load-bearing, and each of them is a wrong
/// ring if it is read the other way:
///
/// - **`hard_limit_usd` is not "money left".** It is the total, so the
///   percentage is `spent / hard_limit_usd` and the remaining money is the
///   difference. Read as a balance, a healthy account draws a full ring.
/// - **`total_usage` is cumulative and the date parameters are ignored.**
///   Measured against a live gateway: `?start_date=…&end_date=…` returns the
///   same figure as no parameters at all. So there is no window here, no
///   reset, and nothing to chart — this is a ledger total, not an allowance
///   that turns over.
/// - **`100000000` is not a limit.** A token with `unlimited_quota` set comes
///   back with the allowance forced to exactly that sentinel — which is how a
///   company-issued key usually reads, and what the first gateway this was
///   written against returned. A ring drawn against it sits at 0% for ever, so
///   it is read as "no limit reported": the denominator then comes from a
///   figure the reader typed, and the row says `of your budget` because the
///   number is theirs and not the gateway's. That is the same labelled
///   exception DeepSeek's prepaid balance is.
/// - **A refusal can arrive as HTTP 200.** These two handlers reply
///   `200 {"error":{…}}` when the account lookup fails, so a missing figure is
///   a failed read and never a zero.
///
/// Where the gateway *does* report a ceiling, the percentage is the gateway's
/// own arithmetic on its own two figures and nothing here is inferred.
struct NewAPIUsageService: Sendable {
    let enteredKey: String?
    /// The site the gateway answers on, as the reader typed it.
    ///
    /// Self-hosted software, so there is no address to default to; nothing is
    /// requested until one is entered. `https://host`, `host` and the
    /// `/v1`-suffixed base an OpenAI client is configured with all name the
    /// same site, which is what `baseURL(_:)` is for.
    let address: String?
    /// What the reader expects this key to be allowed to spend. Used **only**
    /// where the gateway reports no limit of its own; blank leaves that case
    /// with nothing to measure against, which is reported rather than drawn.
    let budget: Double?

    /// new-api's "there is no ceiling here" figure.
    ///
    /// `controller/billing.go` forces `amount = 100000000` for a token whose
    /// `unlimited_quota` is set, on all three `*_limit_usd` fields at once.
    /// Compared with `>=` rather than `==`: any real allowance within reach of
    /// this figure is an allowance nobody is watching.
    static let unlimited = 100_000_000.0

    // MARK: - Fetching

    func fetch() async -> ProviderUsage {
        guard let base = Self.baseURL(address) else {
            return .unavailable(.newAPI, reason: .gatewayAddressMissing)
        }
        guard let key = enteredKey.flatMap({ $0.isEmpty ? nil : $0 }) else {
            return .unavailable(.newAPI, reason: .apiKeyMissing)
        }

        // Asked first and never allowed to fail the reading: it names the unit
        // the money is in, and a site that will not answer it still answers the
        // two routes that carry the figures.
        let currency = await Self.currency(base: base)

        let subscriptionData: Data
        switch await Self.reply(Self.subscriptionURL(base), key: key) {
        case .problem(let reason): return .unavailable(.newAPI, reason: reason)
        case .data(let data): subscriptionData = data
        }

        guard let hardLimit = try? JSONDecoder()
            .decode(Subscription.self, from: subscriptionData).hardLimitUSD
        else { return .unavailable(.newAPI, reason: .unreadableReply) }

        let usageData: Data
        switch await Self.reply(Self.usageURL(base), key: key) {
        case .problem(let reason): return .unavailable(.newAPI, reason: reason)
        case .data(let data): usageData = data
        }

        guard let spent = try? JSONDecoder().decode(Usage.self, from: usageData).spent
        else { return .unavailable(.newAPI, reason: .unreadableReply) }

        return Self.reading(spent: spent, hardLimitUSD: hardLimit, currency: currency, budget: budget)
    }

    /// One GET, with the credential, reduced to the three answers that matter.
    private enum Reply {
        case data(Data)
        case problem(ProviderUsage.Unavailability)
    }

    private static func reply(_ url: URL, key: String) async -> Reply {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await NetworkSession.shared.data(for: request) else {
            return .problem(.unreachable)
        }

        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return .data(data)
        // The gateway's token check, which is the same 401 its chat route
        // gives an editor holding a bad key.
        case 401, 403: return .problem(.apiKeyRefused)
        case 429: return .problem(.rateLimited)
        default: return .problem(.serverError)
        }
    }

    /// The unit the figures are denominated in, from the site's own status
    /// reply. Nil where the site says tokens rather than money, and where it
    /// says nothing at all — a figure is then shown as a number rather than
    /// under a currency symbol nobody reported.
    static func currency(base: URL) async -> String? {
        var request = URLRequest(url: statusURL(base))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await NetworkSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        return currency(fromStatus: data)
    }

    /// `quota_display_type`, which the console reads to decide whether to print
    /// dollars, yuan or tokens.
    static func currency(fromStatus data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any],
              let kind = payload["quota_display_type"] as? String
        else { return nil }

        // Anything else — `TOKENS`, or a mode a later version adds — is not a
        // currency, and inventing a symbol for it would be worse than a plain
        // number.
        switch kind.uppercased() {
        case "USD": return "USD"
        case "CNY": return "CNY"
        default: return nil
        }
    }

    // MARK: - Mapping

    /// What the reply says has been spent, in the unit the site displays.
    ///
    /// **Divided by 100 because the field is in cents**, the convention OpenAI's
    /// dashboard set and this route copies. `total_usage` at `710014.4736` is
    /// $7,100.14 spent, not seven million.
    static func spent(fromUsageTotal total: Double) -> Double? {
        guard total.isFinite else { return nil }
        return max(total / 100, 0)
    }

    /// The allowance the gateway states, or nil where it states none.
    ///
    /// A zero is a key with nothing left to spend, which is what the reply
    /// genuinely says; the sentinel is the reply saying nothing.
    static func ceiling(fromHardLimitUSD limit: Double) -> Double? {
        guard limit.isFinite, limit > 0, limit < unlimited else { return nil }
        return limit
    }

    /// At most one row, because there is at most one denominator.
    ///
    /// The gateway's own figure when it states one — and then nothing here is
    /// inferred. Otherwise the reader's budget, marked, because a percentage
    /// against a number the reader typed is theirs and not the gateway's.
    /// Otherwise nothing at all: a ring needs a denominator, and drawing one
    /// against the unlimited sentinel is a ring pinned near zero for ever,
    /// which reads as a healthy account that will never change.
    ///
    /// No length and no reset, ever. This ledger only ever grows, so
    /// `reportsLength` is false and the seconds exist only to sort the row.
    static func windows(spent: Double, ceiling: Double?, budget: Double?) -> [UsageWindow] {
        let denominator: (limit: Double, estimate: UsageWindow.Estimate?)?
        if let ceiling, ceiling.isFinite, ceiling > 0 {
            denominator = (ceiling, nil)
        } else if let budget, budget.isFinite, budget > 0 {
            // **Finite, not merely positive.** `Double("inf")` is greater than
            // zero and an infinite denominator makes the fraction NaN, which
            // `min`/`max` propagate rather than clamp and `Int(_:)` traps on.
            denominator = (budget, .yourBudget)
        } else {
            denominator = nil
        }

        guard let denominator else { return [] }
        let fraction = spent.isFinite ? max(spent / denominator.limit, 0) : 0

        return [
            UsageWindow(
                id: "spend",
                // A money ceiling rather than a pool of tokens: `Kind.spend`
                // is what Command Code's dollar limits are, and this is the
                // same shape of thing.
                kind: .spend,
                // No scope: this gateway's limit is not scoped to a model, and
                // the name is a product name `--json` promises is untranslated.
                scope: nil,
                usedFraction: fraction,
                windowSeconds: 30 * 86_400,
                resetsAt: nil,
                reportsLength: false,
                estimate: denominator.estimate,
                // **Nothing here may claim the key is spent.** new-api has a
                // verdict for that in other replies — a spend limit running
                // past 100 — and this route does not carry it, so arithmetic
                // at 100% is not the gateway saying so.
                isExhausted: false
            )
        ]
    }

    /// The whole reading, from figures that have already been read.
    ///
    /// Split out from `fetch()` so the mapping can be driven against captured
    /// replies: the sentinel, the unit and the arithmetic are the feature, and
    /// none of them needs the network to be checked.
    static func reading(
        spent: Double,
        hardLimitUSD: Double,
        currency: String?,
        budget: Double?
    ) -> ProviderUsage {
        let ceiling = ceiling(fromHardLimitUSD: hardLimitUSD)
        let windows = windows(spent: spent, ceiling: ceiling, budget: budget)

        // No denominator anywhere: a complete answer about a real figure, so
        // it is reported as a configuration gap rather than drawn as a ring
        // measuring against nothing.
        guard !windows.isEmpty else {
            return .unavailable(.newAPI, reason: .gatewayNoAllowance)
        }

        // With a ceiling the money is what is **left**, which is what the
        // shared "Credit balance" row means. Measured against the reader's own
        // budget it is what is **gone**, and the row says so instead.
        let stated = ceiling.map { max($0 - spent, 0) }
        return ProviderUsage(
            account: AccountKey(.newAPI),
            windows: windows,
            observedAt: Date(),
            state: .live,
            plan: nil,
            creditBalance: money(stated ?? spent, currency: currency),
            creditIsSpent: stated == nil
        )
    }

    /// Money, or a bare number where the site named no currency.
    ///
    /// The exact figure, not the ring's short form: this lands in the card and
    /// in Settings, both of which have the room.
    static func money(_ value: Double, currency: String?) -> String {
        guard let currency else {
            return value.formatted(
                .number.precision(.fractionLength(0...2)).locale(LocalizationSource.locale)
            )
        }
        return value.formatted(
            .currency(code: currency)
                .precision(.fractionLength(2))
                .locale(LocalizationSource.locale)
        )
    }

    // MARK: - Addresses

    /// The site root, from whatever the reader typed.
    ///
    /// An OpenAI client is configured with the `/v1` base, so that suffix is
    /// what most people have in their clipboard — and these routes hang off
    /// the site root, not off `/v1`. Anything that is not a URL with a host is
    /// refused rather than guessed at, which is why a blank field reports as a
    /// missing address instead of requesting `https://`.
    static func baseURL(_ typed: String?) -> URL? {
        guard var text = typed?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty
        else { return nil }

        if !text.lowercased().hasPrefix("http://"), !text.lowercased().hasPrefix("https://") {
            text = "https://" + text
        }
        while text.hasSuffix("/") { text.removeLast() }
        if text.lowercased().hasSuffix("/v1") { text.removeLast(3) }
        while text.hasSuffix("/") { text.removeLast() }

        guard let url = URL(string: text), let host = url.host, !host.isEmpty else { return nil }
        return url
    }

    static func subscriptionURL(_ base: URL) -> URL {
        base.appending(path: "v1/dashboard/billing/subscription")
    }

    static func usageURL(_ base: URL) -> URL {
        base.appending(path: "v1/dashboard/billing/usage")
    }

    static func statusURL(_ base: URL) -> URL {
        base.appending(path: "api/status")
    }

    // MARK: - The replies

    /// `{"object":"billing_subscription","hard_limit_usd":…}`
    ///
    /// Every field optional, and a missing `hard_limit_usd` treated as a failed
    /// read by the caller: these handlers report a lookup failure as `200`
    /// with an `error` object and no figures at all.
    struct Subscription: Decodable {
        let hardLimitUSD: Double?
        let softLimitUSD: Double?

        enum CodingKeys: String, CodingKey {
            case hardLimitUSD = "hard_limit_usd"
            case softLimitUSD = "soft_limit_usd"
        }
    }

    /// `{"object":"list","total_usage":710014.4736}` — **in cents**.
    struct Usage: Decodable {
        let totalUsage: Double?

        enum CodingKeys: String, CodingKey {
            case totalUsage = "total_usage"
        }

        /// What is gone, in the unit the site displays.
        var spent: Double? { totalUsage.flatMap(NewAPIUsageService.spent(fromUsageTotal:)) }
    }
}
