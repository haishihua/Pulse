import Foundation

/// A self-hosted **New API** gateway — the software most "中转站" run.
///
/// [New API](https://github.com/QuantumNous/new-api) is an OpenAI-compatible
/// relay that also keeps the account's own ledger, and it answers the same
/// routes its own console reads. Pulse reads the account with the console's
/// **access token** — the one the site's Security page issues — because the
/// `sk-…` key an editor is configured with cannot see the account at all:
/// measured against a live gateway, `/api/subscription/self` and
/// `/api/user/self` both answer `401` to it. The token travels exactly as
/// new-api's own PAT contract describes it, `Authorization: Bearer <token>`,
/// with no second header.
///
/// | Call | What it holds |
/// |---|---|
/// | `GET /api/status` | `quota_display_type`, `quota_per_unit`, `usd_exchange_rate` — public, no credential |
/// | `GET /api/subscription/self` | the account's subscriptions: `amount_total`, `amount_used`, `next_reset_time` |
/// | `GET /api/user/self` | the wallet: `quota` left, `used_quota` spent |
///
/// **Every money figure in these replies is in quota units, not dollars.**
/// `quota_per_unit` (500000 on the gateway this was written against) is what
/// converts them, and `quota_display_type` decides whether the result is
/// printed as dollars, yuan or bare tokens — the same two fields the console's
/// own formatter reads. Reading them as dollars draws a ¥200 allowance as
/// $100,000,000.
///
/// Four things about the replies are load-bearing, and each of them is a wrong
/// ring if it is read the other way:
///
/// - **A subscription states both of its own figures**, so the percentage is
///   `amount_used / amount_total`: the gateway's arithmetic on the gateway's
///   numbers, and nothing here is inferred. Where the account has **no**
///   subscription there is no ceiling anywhere in these routes, and the ring
///   falls back to a budget the reader typed — marked as theirs.
/// - **The reset is the plan's, not a calendar's.** `next_reset_time` is when
///   the allowance turns over, and `last_reset_time` beside it is what makes
///   the window's *length* a figure from the reply rather than a guess. A plan
///   can also reset `never`, in which case the subscription's own `end_time`
///   is the one date there is.
/// - **Money is only ever what is left.** Both routes report a balance —
///   `amount_total − amount_used`, and the wallet's `quota` — so the card's
///   "Credit balance" row means what it says on every path through this file.
/// - **A refusal can arrive as HTTP 200.** These handlers answer
///   `200 {"success":false,…}` when the lookup fails, so a missing figure is a
///   failed read and never a zero.
struct NewAPIUsageService: Sendable {
    /// The console's access token, as typed into Settings.
    let accessToken: String?
    /// The site the gateway answers on, as the reader typed it.
    ///
    /// Self-hosted software, so there is no address to default to; nothing is
    /// requested until one is entered. `https://host`, `host` and the
    /// `/v1`-suffixed base an OpenAI client is configured with all name the
    /// same site, which is what `baseURL(_:)` is for.
    let address: String?
    /// What the reader expects this account to spend. Used **only** where the
    /// account has no subscription of its own to measure against; blank leaves
    /// that case showing the wallet's balance and no ring, which is what a
    /// prepaid balance alone can honestly support.
    let budget: Double?

    // MARK: - Fetching

    func fetch() async -> ProviderUsage {
        guard let base = Self.baseURL(address) else {
            return .unavailable(.newAPI, reason: .gatewayAddressMissing)
        }
        guard let token = Self.token(accessToken) else {
            return .unavailable(.newAPI, reason: .gatewayTokenMissing)
        }

        // Asked first and never allowed to fail the reading: it names the unit
        // the money is in, and a site that will not answer it still answers the
        // routes that carry the figures.
        let status = await Self.status(base: base)

        let subscriptions: Data
        switch await Self.reply(Self.subscriptionURL(base), token: token) {
        case .problem(let reason): return .unavailable(.newAPI, reason: reason)
        case .data(let data): subscriptions = data
        }

        guard let plans = Self.plans(fromSelf: subscriptions) else {
            return .unavailable(.newAPI, reason: .unreadableReply)
        }
        if let reading = Self.planReading(plans, status: status) { return reading }

        // No subscription running on the account: the wallet is the whole
        // story, and it is the only figure the second route carries.
        let wallet: Data
        switch await Self.reply(Self.walletURL(base), token: token) {
        case .problem(let reason): return .unavailable(.newAPI, reason: reason)
        case .data(let data): wallet = data
        }

        guard let figures = Self.wallet(fromSelf: wallet) else {
            return .unavailable(.newAPI, reason: .unreadableReply)
        }
        return Self.walletReading(
            remainingQuota: figures.remaining, spentQuota: figures.spent,
            status: status, budget: budget
        )
    }

    /// One GET, with the access token, reduced to the three answers that matter.
    private enum Reply {
        case data(Data)
        case problem(ProviderUsage.Unavailability)
    }

    private static func reply(_ url: URL, token: String) async -> Reply {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await NetworkSession.shared.data(for: request) else {
            return .problem(.unreachable)
        }

        switch (response as? HTTPURLResponse)?.statusCode {
        case 200: return .data(data)
        // The dashboard's own auth, which is what a wrong or revoked access
        // token answers with — the same 401 the console gives.
        case 401, 403: return .problem(.gatewayTokenRefused)
        case 429: return .problem(.rateLimited)
        default: return .problem(.serverError)
        }
    }

    /// The site's public status reply, or nil where it did not answer.
    static func status(base: URL) async -> Status? {
        var request = URLRequest(url: statusURL(base))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        guard let (data, response) = try? await NetworkSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200
        else { return nil }

        return status(fromStatus: data)
    }

    static func status(fromStatus data: Data) -> Status? {
        (try? JSONDecoder().decode(StatusReply.self, from: data))?.data
    }

    // MARK: - Mapping

    /// The access token, or nil where there is not one to send.
    static func token(_ entered: String?) -> String? {
        let trimmed = entered?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// The unit the figures are printed in, from the site's own status reply.
    ///
    /// Nil where the site says tokens rather than money, and where it says
    /// nothing at all — a figure is then shown as a number rather than under a
    /// currency symbol nobody reported.
    static func currency(_ status: Status?) -> String? {
        switch status?.displayType?.uppercased() {
        case "USD": return "USD"
        case "CNY": return "CNY"
        default: return nil
        }
    }

    /// A quota figure in the unit the site says it displays.
    ///
    /// The console's own three cases, in the console's own order: yuan are
    /// converted from dollars at the site's rate, tokens are passed through as
    /// the raw number, and everything else is dollars.
    static func value(fromQuota quota: Double, status: Status?) -> Double? {
        guard quota.isFinite else { return nil }

        switch status?.displayType?.uppercased() {
        case "CNY":
            guard let rate = status?.usdExchangeRate, rate.isFinite, rate > 0 else { return nil }
            return quota / unit(status) * rate
        case "TOKENS":
            return quota
        default:
            return quota / unit(status)
        }
    }

    /// `quota_per_unit` — how many quota units make one unit of the displayed
    /// money.
    ///
    /// The software's own default stands in where the status route did not
    /// answer: without it every figure would be out by five orders of
    /// magnitude rather than merely unlabelled, and 500000 is the constant
    /// new-api ships (`common.QuotaPerUnit`).
    static func unit(_ status: Status?) -> Double {
        if let unit = status?.quotaPerUnit, unit.isFinite, unit > 0 { return unit }
        return 500_000
    }

    /// The same figure as a number and a currency, for anything that has to
    /// compare money against money.
    static func credit(_ value: Double, status: Status?) -> ProviderUsage.CreditAmount? {
        guard value.isFinite, let currency = currency(status) else { return nil }
        return ProviderUsage.CreditAmount(amount: value, currency: currency)
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

    // MARK: - The account's own subscription

    /// The account's running subscriptions, soonest to turn over first.
    ///
    /// Nil is a reply that could not be read — a failed decode, or an envelope
    /// that says it failed. An **empty array is a complete answer**: no
    /// subscription is running, which is not a fault and is answered by the
    /// wallet route instead.
    ///
    /// A subscription with no `amount_total` states no ceiling, so it is not a
    /// window: what it would give is a figure with nothing to measure it
    /// against, and the wallet beside it is the better answer.
    static func plans(fromSelf data: Data) -> [Subscription]? {
        guard let reply = try? JSONDecoder().decode(SelfReply.self, from: data),
              reply.success != false
        else { return nil }

        return (reply.data?.subscriptions ?? [])
            .compactMap(\.subscription)
            .filter { $0.isActive && ($0.amountTotal ?? 0) > 0 }
            .sorted { ($0.turnsOverAt ?? .distantFuture) < ($1.turnsOverAt ?? .distantFuture) }
    }

    /// A reading built on the account's subscription: the gateway's own two
    /// figures, the gateway's own reset, and nothing inferred.
    ///
    /// Nil where there is nothing to build one from — the caller then asks the
    /// wallet.
    static func planReading(_ plans: [Subscription], status: Status?) -> ProviderUsage? {
        guard !plans.isEmpty else { return nil }

        // More than one subscription is unusual and possible: the console
        // draws a card per subscription, and Pulse draws a row per
        // subscription, with the money summed across them because that is what
        // is actually left to spend.
        let remaining = plans.reduce(0.0) { total, plan in
            total + max((plan.amountTotal ?? 0) - (plan.amountUsed ?? 0), 0)
        }
        guard let left = value(fromQuota: remaining, status: status) else { return nil }

        return ProviderUsage(
            account: AccountKey(.newAPI),
            windows: plans.map(window(for:)),
            observedAt: Date(),
            state: .live,
            plan: nil,
            creditBalance: money(left, currency: currency(status)),
            creditIsSpent: false,
            creditRemaining: credit(left, status: status),
            origin: .endpoint
        )
    }

    /// One row per subscription, drawn from the subscription's own figures.
    static func window(for plan: Subscription) -> UsageWindow {
        let total = plan.amountTotal ?? 0
        let used = plan.amountUsed ?? 0
        // A plan can be overspent — usage past the total is a real state and is
        // reported rather than clamped, exactly as an overrun on any other
        // provider's window is.
        let fraction = total > 0 && used.isFinite ? max(used / total, 0) : 0
        let period = plan.periodSeconds

        return UsageWindow(
            id: "subscription-\(plan.id.map(String.init) ?? "0")",
            // The plan's own period where its two clocks state one — a monthly
            // plan reads "Monthly limit" — and `.spend` where they do not,
            // which names the shape without claiming a length nobody gave.
            kind: period.map(kind(seconds:)) ?? .spend,
            scope: nil,
            usedFraction: fraction,
            windowSeconds: period ?? 30 * 86_400,
            resetsAt: plan.turnsOverAt,
            reportsLength: period != nil,
            estimate: nil,
            // **Nothing here may claim the allowance is spent.** `status` is
            // the subscription's own state and says whether the plan is
            // running, not whether the money is gone; arithmetic at 100% is not
            // the gateway saying so either.
            isExhausted: false
        )
    }

    /// The period's name, from the period itself.
    ///
    /// A plan that resets daily reads "Daily limit" and one that resets monthly
    /// reads "Monthly limit", because those are the lengths the gateway's own
    /// two timestamps describe. Calendar months are 28 to 31 days and years 365,
    /// so the monthly and weekly windows are ranges rather than single figures;
    /// anything else keeps its seconds and reads "N-day limit".
    static func kind(seconds: Int) -> UsageWindow.Kind {
        let days = Double(seconds) / 86_400
        switch days {
        case 0.75...1.25: return .daily
        case 6...8: return .weekly
        case 26...32: return .monthly
        default: return .other(seconds: seconds)
        }
    }

    /// One subscription instance, as `model.UserSubscription` marshals it.
    ///
    /// Every field optional: the struct has grown over the project's life, and
    /// a field a given build does not send is **absent rather than zero**.
    struct Subscription: Decodable {
        let id: Int?
        let status: String?
        /// The allowance and what is gone from it, **in quota units**.
        let amountTotal: Double?
        let amountUsed: Double?
        let startTime: Double?
        let endTime: Double?
        let lastResetTime: Double?
        let nextResetTime: Double?

        enum CodingKeys: String, CodingKey {
            case id, status
            case amountTotal = "amount_total"
            case amountUsed = "amount_used"
            case startTime = "start_time"
            case endTime = "end_time"
            case lastResetTime = "last_reset_time"
            case nextResetTime = "next_reset_time"
        }

        /// Whether the plan is running. An absent status counts as running:
        /// the route this arrives on already lists active subscriptions alone.
        var isActive: Bool { status.map { $0.lowercased() == "active" } ?? true }

        /// When the allowance turns over: the plan's own reset where it resets
        /// its quota, and the day the subscription ends where it does not.
        ///
        /// Both are the gateway's figures, and the second is not a stand-in for
        /// the first — a subscription that never resets its quota does end, and
        /// that is what its allowance turns over into.
        var turnsOverAt: Date? { Self.date(nextResetTime) ?? Self.date(endTime) }

        /// How long one turn of the allowance is, where the reply's own two
        /// timestamps say so.
        ///
        /// `next_reset_time − last_reset_time` is a period the plan states by
        /// way of its own two clocks; `end_time − start_time` is the same answer
        /// for a subscription that never resets. Nothing else is a length: a
        /// figure with no second timestamp beside it gets a sort key and
        /// `reportsLength` false, which is what keeps an elapsed arc nobody
        /// reported off the card.
        var periodSeconds: Int? {
            guard let turnsOverAt, let anchor = Self.date(lastResetTime) ?? Self.date(startTime)
            else { return nil }

            let seconds = turnsOverAt.timeIntervalSince(anchor)
            // An hour at the shortest — a plan may reset hourly — and a little
            // over a year at the longest. Anything outside that is two
            // timestamps that were never a period.
            guard seconds >= 3_600, seconds <= 400 * 86_400 else { return nil }
            return Int(seconds)
        }

        static func date(_ unix: Double?) -> Date? {
            guard let unix, unix.isFinite, unix > 0 else { return nil }
            return Date(timeIntervalSince1970: unix)
        }
    }

    /// `{"success":true,"message":"","data":{"billing_preference":…,
    /// "subscriptions":[{"subscription":{…}}],"all_subscriptions":[…]}}`
    struct SelfReply: Decodable {
        let success: Bool?
        let data: Payload?

        struct Payload: Decodable {
            let subscriptions: [Record]?
        }

        struct Record: Decodable {
            let subscription: Subscription?
        }
    }

    // MARK: - The wallet, where no subscription is running

    /// The wallet's two figures, **in quota units**.
    ///
    /// `quota` is what is left and `used_quota` what is gone — the console
    /// prints the first as "Current Balance" and the second as "Total Usage",
    /// and these are that pair. Nil is a reply that could not be read, which
    /// includes the `200 {"success":false,…}` these handlers answer when the
    /// account lookup fails.
    static func wallet(fromSelf data: Data) -> (remaining: Double, spent: Double)? {
        guard let reply = try? JSONDecoder().decode(WalletReply.self, from: data),
              reply.success != false,
              let payload = reply.data,
              let quota = payload.quota, quota.isFinite
        else { return nil }

        let spent = payload.usedQuota ?? 0
        return (quota, spent.isFinite ? spent : 0)
    }

    /// The prepaid balance, and a ring where the reader has said what a full
    /// tank is.
    ///
    /// A wallet states no ceiling of its own — money in it is what was topped
    /// up, and what is spent is gone — so the only denominator available is the
    /// reader's, marked as theirs on the row and in `--json` exactly as
    /// DeepSeek's is.
    static func walletReading(
        remainingQuota: Double, spentQuota: Double, status: Status?, budget: Double?
    ) -> ProviderUsage {
        let window = budgetWindow(spentQuota: spentQuota, budget: budget, status: status)
        let left = value(fromQuota: remainingQuota, status: status)

        return ProviderUsage(
            account: AccountKey(.newAPI),
            windows: window.map { [$0] } ?? [],
            observedAt: Date(),
            state: .live,
            plan: nil,
            creditBalance: left.map { money($0, currency: currency(status)) },
            creditIsSpent: false,
            creditRemaining: left.flatMap { credit($0, status: status) },
            origin: .endpoint
        )
    }

    /// The reader's own figure, marked as theirs.
    ///
    /// **Finite, not merely positive.** `Double("inf")` is greater than zero,
    /// an infinite denominator makes the fraction NaN, `min`/`max` propagate
    /// NaN rather than clamping it, and `Int(_:)` traps on it — which,
    /// persisted, crashed the panel on every launch the first time DeepSeek
    /// shipped that bug.
    static func budgetWindow(spentQuota: Double, budget: Double?, status: Status?) -> UsageWindow? {
        guard let budget, budget.isFinite, budget > 0,
              let spent = value(fromQuota: spentQuota, status: status), spent.isFinite
        else { return nil }

        return UsageWindow(
            id: "spend",
            // A money ceiling the reader typed: the shape Command Code's dollar
            // limits have, with the denominator named as not the provider's.
            kind: .spend,
            scope: nil,
            usedFraction: max(spent / budget, 0),
            // No length and no reset: a wallet's ledger only grows, so the
            // seconds exist only to sort the row.
            windowSeconds: 30 * 86_400,
            resetsAt: nil,
            reportsLength: false,
            estimate: .yourBudget,
            // Nothing here claims the account is spent: this route carries no
            // verdict, and arithmetic past a reader's own budget is not one.
            isExhausted: false
        )
    }

    /// `{"success":true,"data":{"quota":…,"used_quota":…}}`
    struct WalletReply: Decodable {
        let success: Bool?
        let data: Payload?

        struct Payload: Decodable {
            let quota: Double?
            let usedQuota: Double?

            enum CodingKeys: String, CodingKey {
                case quota
                case usedQuota = "used_quota"
            }
        }
    }

    // MARK: - The unit

    /// `GET /api/status` — public, no credential.
    ///
    /// The three fields the console's own currency formatter is built on, and
    /// the only reason money is printed under a symbol rather than as a bare
    /// number.
    struct Status: Decodable {
        let displayType: String?
        let quotaPerUnit: Double?
        let usdExchangeRate: Double?

        enum CodingKeys: String, CodingKey {
            case displayType = "quota_display_type"
            case quotaPerUnit = "quota_per_unit"
            case usdExchangeRate = "usd_exchange_rate"
        }
    }

    struct StatusReply: Decodable {
        let data: Status?
    }

    // MARK: - Addresses

    /// The site root, from whatever the reader typed.
    ///
    /// An OpenAI client is configured with the `/v1` base, so that suffix is
    /// what most people have in their clipboard — and these routes hang off the
    /// site root, not off `/v1`. Anything that is not a URL with a host is
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
        base.appending(path: "api/subscription/self")
    }

    static func walletURL(_ base: URL) -> URL {
        base.appending(path: "api/user/self")
    }

    static func statusURL(_ base: URL) -> URL {
        base.appending(path: "api/status")
    }
}
