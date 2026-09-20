import Foundation
import Testing
@testable import Pulse

/// New API is the first provider here that is **somebody's own site** rather
/// than a vendor's, so everything about it begins with two things the reader
/// typed: the address, and the console's **access token**.
///
/// The status fixture is a live gateway's own reply, trimmed to the three
/// fields this reads. The subscription and wallet fixtures are written to the
/// shapes new-api marshals itself — `model.UserSubscription`'s own JSON tags
/// and the dashboard user payload — because those routes cannot be called
/// without somebody's token. What they hold is **quota units**, and nothing but
/// a test catches a figure read as dollars: 100000000 is $200 at the 500000 to
/// the dollar this gateway reports, not a hundred million dollars.
@Suite("New API gateway")
struct NewAPIUsageTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private static func status() throws -> NewAPIUsageService.Status {
        try #require(NewAPIUsageService.status(fromStatus: try fixture("newapi-status")))
    }

    private static func plans() throws -> [NewAPIUsageService.Subscription] {
        try #require(NewAPIUsageService.plans(fromSelf: try fixture("newapi-subscription-self")))
    }

    private static func wallet() throws -> (remaining: Double, spent: Double) {
        try #require(NewAPIUsageService.wallet(fromSelf: try fixture("newapi-user-self")))
    }

    /// One subscription, at a chosen set of figures.
    private static func plan(
        total: Double?, used: Double?, lastReset: Double? = nil, nextReset: Double? = nil,
        start: Double? = nil, end: Double? = nil, status: String? = "active"
    ) throws -> NewAPIUsageService.Subscription {
        var fields: [String] = ["\"id\":9"]
        if let status { fields.append("\"status\":\"\(status)\"") }
        if let total { fields.append("\"amount_total\":\(total)") }
        if let used { fields.append("\"amount_used\":\(used)") }
        if let lastReset { fields.append("\"last_reset_time\":\(lastReset)") }
        if let nextReset { fields.append("\"next_reset_time\":\(nextReset)") }
        if let start { fields.append("\"start_time\":\(start)") }
        if let end { fields.append("\"end_time\":\(end)") }
        let body = #"{"success":true,"data":{"subscriptions":[{"subscription":{"#
            + fields.joined(separator: ",") + "}}]}}"
        let plans = try #require(NewAPIUsageService.plans(fromSelf: Data(body.utf8)))
        return try #require(plans.first)
    }

    // MARK: - The unit

    /// The site names its own display unit, and `quota_per_unit` is what turns
    /// its figures into money. Both are a live gateway's own fields.
    @Test("The status route names the unit and the rate")
    func theSiteNamesItsOwnUnit() throws {
        let status = try Self.status()
        #expect(status.displayType == "USD")
        #expect(status.quotaPerUnit == 500_000)
        #expect(status.usdExchangeRate == 7.3)
        #expect(NewAPIUsageService.currency(status) == "USD")

        // Tokens are not a currency, and neither is a reply that says nothing.
        #expect(NewAPIUsageService.currency(
            NewAPIUsageService.Status(displayType: "TOKENS", quotaPerUnit: 500_000, usdExchangeRate: nil)
        ) == nil)
        #expect(NewAPIUsageService.currency(nil) == nil)
        #expect(NewAPIUsageService.status(fromStatus: Data(#"{"success":true}"#.utf8)) == nil)
    }

    /// **Quota units, not dollars.** Read straight, the captured subscription
    /// states $100,000,000 of allowance; it is $200.
    @Test("Quota units become the site's own money")
    func quotaUnitsBecomeMoney() throws {
        let status = try Self.status()
        #expect(NewAPIUsageService.value(fromQuota: 100_000_000, status: status) == 200)
        #expect(NewAPIUsageService.value(fromQuota: 13_895_000, status: status) == 27.79)

        // Yuan, at the site's own rate.
        let yuan = NewAPIUsageService.Status(displayType: "CNY", quotaPerUnit: 500_000, usdExchangeRate: 7.3)
        let converted = try #require(NewAPIUsageService.value(fromQuota: 100_000_000, status: yuan))
        #expect(abs(converted - 1_460) < 0.000_001)

        // Tokens are passed through: the site prints raw quota numbers.
        let tokens = NewAPIUsageService.Status(displayType: "TOKENS", quotaPerUnit: 500_000, usdExchangeRate: nil)
        #expect(NewAPIUsageService.value(fromQuota: 13_895_000, status: tokens) == 13_895_000)

        // A site that did not answer the status route falls back to the
        // software's own constant rather than to a figure five orders of
        // magnitude out.
        #expect(NewAPIUsageService.unit(nil) == 500_000)
        #expect(NewAPIUsageService.value(fromQuota: 100_000_000, status: nil) == 200)

        // And a figure that is not one stays not one.
        #expect(NewAPIUsageService.value(fromQuota: .nan, status: status) == nil)
        #expect(NewAPIUsageService.value(fromQuota: .infinity, status: status) == nil)
    }

    @Test("Money without a currency is a number, not a symbol")
    func moneyWithoutACurrencyIsANumber() throws {
        #expect(NewAPIUsageService.money(1_234.5, currency: nil) == "1,234.5")
        #expect(NewAPIUsageService.money(172.21, currency: "USD") == "$172.21")
        // The number-and-currency pair the low-balance line is built on exists
        // only where there is a currency to compare in.
        #expect(NewAPIUsageService.credit(172.21, status: nil) == nil)
        #expect(NewAPIUsageService.credit(172.21, status: try Self.status())?.currency == "USD")
    }

    @Test("The token is sent as it stands, and an empty field is not one")
    func theTokenIsSentAsItStands() {
        #expect(NewAPIUsageService.token("  pat-abc  ") == "pat-abc")
        #expect(NewAPIUsageService.token("") == nil)
        #expect(NewAPIUsageService.token("   ") == nil)
        #expect(NewAPIUsageService.token(nil) == nil)
    }

    // MARK: - The account's subscription

    /// The whole reason this service reads with a token: the account's plan,
    /// with the gateway's own total, its own usage and its own reset time.
    @Test("The reply's subscription is the account's, in quota units")
    func theSubscriptionIsTheAccounts() throws {
        let plans = try Self.plans()
        // The expired one a reply may still list is not a window, and the
        // route's own list is the one that counts.
        #expect(plans.count == 1)
        let plan = try #require(plans.first)
        #expect(plan.id == 7)
        #expect(plan.amountTotal == 100_000_000)
        #expect(plan.amountUsed == 13_895_000)

        let reading = try #require(NewAPIUsageService.planReading(plans, status: try Self.status()))
        let window = try #require(reading.windows.first)

        #expect(reading.state == .live)
        #expect(reading.windows.count == 1)
        #expect(abs(window.usedFraction - 0.13895) < 0.000_001)
        #expect(window.kind == .monthly)
        // The gateway states both figures, so nothing here is an estimate.
        #expect(window.estimate == nil)
        #expect(window.isEstimated == false)
        #expect(window.scope == nil)
        // Money **left**, which is what the card's row means: nothing here is
        // a spend dressed up as a balance.
        #expect(reading.creditBalance == "$172.21")
        #expect(reading.creditIsSpent == false)
        assertMoney(reading.creditRemaining?.amount, isCloseTo: 172.21)
        #expect(reading.origin == .endpoint)
    }

    /// The reset is the plan's, and so is the window's length: both come from
    /// the two clocks the reply carries.
    @Test("The reset and the window's length are the plan's own")
    func theResetIsThePlansOwn() throws {
        let window = NewAPIUsageService.window(for: try Self.plan(
            total: 100_000_000, used: 13_895_000,
            lastReset: 1_755_720_000, nextReset: 1_758_384_000
        ))

        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_758_384_000))
        #expect(window.windowSeconds == 2_664_000)
        // A length the reply stated, so the elapsed arc may be drawn from it.
        #expect(window.reportsLength)
        let halfway = Date(timeIntervalSince1970: 1_758_384_000 - 1_332_000)
        #expect(window.elapsedFraction(at: halfway) == 0.5)
    }

    /// A plan that never resets its quota ends instead, and that date is when
    /// its allowance turns over.
    @Test("A subscription that never resets ends instead")
    func aSubscriptionThatNeverResetsEndsInstead() throws {
        let window = NewAPIUsageService.window(for: try Self.plan(
            total: 5_000_000, used: 1_000_000,
            lastReset: 0, nextReset: 0, start: 1_755_720_000, end: 1_760_990_400
        ))

        #expect(window.resetsAt == Date(timeIntervalSince1970: 1_760_990_400))
        #expect(window.windowSeconds == 5_270_400)
        // 61 days, which is not a month and does not claim to be.
        #expect(window.kind == .other(seconds: 5_270_400))
        #expect(window.reportsLength)
    }

    /// No timestamps at all: a length nobody gave, so the seconds are a sort
    /// key and the row says so.
    @Test("A plan with no clocks gets no length, and no reset")
    func aPlanWithNoClocksGetsNoLength() throws {
        let window = NewAPIUsageService.window(for: try Self.plan(total: 5_000_000, used: 1_000_000))

        #expect(window.resetsAt == nil)
        #expect(window.reportsLength == false)
        #expect(window.windowSeconds == 2_592_000)
        #expect(window.kind == .spend)
        #expect(window.elapsedFraction(at: Date()) == nil)
    }

    /// A total of zero is the plan saying it has no ceiling. That is not a
    /// window, and what it would draw is a ring pinned at zero.
    @Test("A plan with no total states no ceiling")
    func aPlanWithNoTotalStatesNoCeiling() throws {
        let data = Data(#"{"success":true,"data":{"subscriptions":[{"subscription":{"id":9,"status":"active","amount_total":0,"amount_used":1000000}}]}}"#.utf8)
        let plans = try #require(NewAPIUsageService.plans(fromSelf: data))

        #expect(plans.isEmpty)
        // And nothing to build a reading from, so the caller asks the wallet.
        #expect(NewAPIUsageService.planReading(plans, status: nil) == nil)
    }

    /// Going past the total is a real state — a plan can be overspent before it
    /// resets, because the wallet behind it is what actually pays — and it is
    /// reported rather than clamped back to 100%.
    @Test("An overrun is reported rather than clamped away")
    func anOverrunIsReported() throws {
        let plan = try Self.plan(total: 5_000_000, used: 6_000_000)
        let reading = try #require(NewAPIUsageService.planReading([plan], status: try Self.status()))

        #expect(reading.windows.first?.usedFraction == 1.2)
        // Nothing left, and the money row says so.
        #expect(reading.creditBalance == "$0.00")
    }

    /// **Nothing here claims the allowance is spent.** `status` says whether the
    /// plan is running, not whether the money is gone, and arithmetic past the
    /// total is not the gateway saying so either.
    @Test("Spent is never inferred from the arithmetic")
    func spentIsNeverInferred() throws {
        #expect(NewAPIUsageService.window(for: try Self.plan(total: 5_000_000, used: 6_000_000)).isExhausted == false)
        #expect(NewAPIUsageService.window(for: try Self.plan(total: 5_000_000, used: 0)).isExhausted == false)
    }

    // MARK: - The wallet, where no subscription is running

    @Test("With no subscription the wallet is the answer")
    func theWalletIsTheAnswer() throws {
        let wallet = try Self.wallet()
        #expect(wallet.remaining == 50_000_000)
        #expect(wallet.spent == 2_500_000)

        let status = try Self.status()

        // A wallet states no ceiling of its own, so the balance is the reading
        // and no ring is drawn without a figure from the reader.
        let plain = NewAPIUsageService.walletReading(
            remainingQuota: wallet.remaining, spentQuota: wallet.spent, status: status, budget: nil
        )
        #expect(plain.windows.isEmpty)
        #expect(plain.creditBalance == "$100.00")
        #expect(plain.creditIsSpent == false)
    }

    /// A denominator the reader typed is theirs, and every promise the project
    /// makes about inferred percentages holds: the row reads `of your budget`
    /// and `--json` marks it as estimated.
    @Test("A budget is marked as the reader's, and never as the gateway's")
    func aBudgetIsTheReadersFigure() throws {
        let reading = NewAPIUsageService.walletReading(
            remainingQuota: 50_000_000, spentQuota: 2_500_000, status: try Self.status(), budget: 50
        )
        let window = try #require(reading.windows.first)

        #expect(reading.windows.count == 1)
        #expect(window.kind == .spend)
        #expect(window.usedFraction == 0.1)
        #expect(window.estimate == .yourBudget)
        #expect(window.isEstimated)
        #expect(window.reportsLength == false)
        #expect(window.resetsAt == nil)
        // The budget is a denominator, not a new figure: the money row is still
        // the wallet's own balance.
        #expect(reading.creditBalance == "$100.00")
    }

    /// A budget of "inf" parses as a `Double` greater than zero, and an
    /// infinite denominator makes the fraction NaN — which `min`/`max`
    /// propagate rather than clamp, and which `Int(_:)` **traps** on.
    @Test("A budget that cannot be a denominator draws nothing, and never a NaN")
    func aBudgetMustBeAFigure() {
        for budget in [nil, 0, -5, .infinity, -.infinity, .nan] as [Double?] {
            let reading = NewAPIUsageService.walletReading(
                remainingQuota: 50_000_000, spentQuota: 2_500_000, status: nil, budget: budget
            )
            #expect(reading.windows.isEmpty, "budget \(String(describing: budget))")
        }

        // And a spend that is not a figure cannot be one side of a fraction.
        #expect(NewAPIUsageService.budgetWindow(spentQuota: .nan, budget: 50, status: nil) == nil)
    }

    // MARK: - Refusals and absences

    /// `common.ApiError` answers **HTTP 200** with `success:false` when the
    /// lookup fails, and a figure that is absent is absent — never a zero,
    /// which is a balance saying the account is untouched.
    @Test("A refusal is not an empty account")
    func aRefusalIsNotAnEmptyAccount() {
        let refused = Data(#"{"success":false,"message":"无效的令牌"}"#.utf8)
        #expect(NewAPIUsageService.plans(fromSelf: refused) == nil)
        #expect(NewAPIUsageService.wallet(fromSelf: refused) == nil)

        // An empty subscription list **is** an answer: it sends the reader to
        // the wallet rather than reporting a fault.
        let none = Data(#"{"success":true,"message":"","data":{"billing_preference":"subscription_first","subscriptions":[]}}"#.utf8)
        #expect(NewAPIUsageService.plans(fromSelf: none)?.isEmpty == true)

        // An account with no wallet figure at all is a failed read.
        #expect(NewAPIUsageService.wallet(fromSelf: Data(#"{"success":true,"data":{"id":3}}"#.utf8)) == nil)
    }

    // MARK: - The address

    /// Self-hosted software, so this is the one thing that cannot be known in
    /// advance. What an editor is configured with is the `/v1` base, which is
    /// what most people have in their clipboard — and the routes this reads
    /// hang off the site root.
    @Test("Every shape of address a reader might paste names the same site")
    func addressesAreNormalised() throws {
        let site = "https://ai.example.cn"

        for typed in [
            "https://ai.example.cn",
            "https://ai.example.cn/",
            "https://ai.example.cn/v1",
            "https://ai.example.cn/v1/",
            "ai.example.cn",
            "  ai.example.cn/v1  ",
        ] {
            let base = try #require(NewAPIUsageService.baseURL(typed), "\(typed)")
            #expect(base.absoluteString == site, "\(typed)")
        }

        // Another scheme and a port are left alone: plenty of these run on a
        // laptop or an intranet address.
        #expect(NewAPIUsageService.baseURL("http://10.0.0.2:3000/v1")?.absoluteString == "http://10.0.0.2:3000")

        // Nothing typed, and nothing usable, are both no address at all —
        // never a request to a guess.
        #expect(NewAPIUsageService.baseURL(nil) == nil)
        #expect(NewAPIUsageService.baseURL("   ") == nil)
        #expect(NewAPIUsageService.baseURL("/v1") == nil)
    }

    @Test("The routes hang off the site root")
    func routesHangOffTheRoot() throws {
        let base = try #require(NewAPIUsageService.baseURL("https://ai.example.cn/v1"))

        #expect(NewAPIUsageService.subscriptionURL(base).absoluteString
            == "https://ai.example.cn/api/subscription/self")
        #expect(NewAPIUsageService.walletURL(base).absoluteString
            == "https://ai.example.cn/api/user/self")
        #expect(NewAPIUsageService.statusURL(base).absoluteString
            == "https://ai.example.cn/api/status")
    }

    // MARK: - The rest of the app

    @Test("The provider is wired up like every other key-based one")
    func theProviderIsWiredUp() {
        let provider = Provider.newAPI

        #expect(provider.displayName == "New API")
        #expect(provider.usesAPIKey)
        #expect(provider.keepsOwnCredential)
        #expect(provider.soleRoute == nil)
        #expect(provider.hasSourceChoice == false)
        #expect(provider.keepsLocalTranscripts == false)
        #expect(provider.providesHistory == false)
        #expect(provider.usesSessionCookie == false)
        // The token reads money **left** on both of its routes — a
        // subscription's remainder and a wallet's balance — so the low-balance
        // line is worth offering, and the money drains on the gateway's own
        // servers, where nothing local moves to show it happening.
        #expect(provider.reportsSpendableBalance)
        #expect(provider.spendingIsWatchedLocally == false)
        // Nothing on this Mac names a gateway, so there is nothing to detect.
        #expect(!Provider.installedOnThisMac().contains(.newAPI))
        #expect(UsageRoute.soleRoute(for: AccountKey(provider)) == .endpoint)
        #expect(provider.supportsMultipleAccounts == false)
        // The mark is never drawn — no CLI of the gateway's runs here — so
        // there is no brand colour to give it.
        #expect(BotMarkTint.brand(for: provider) == nil)
    }

    /// An icon that is not in the bundle draws nothing, and a ring with no mark
    /// is indistinguishable from one that failed to load. Asked through the
    /// app's own loader, because `Bundle.module` inside a test is the *test*
    /// bundle and would answer nil for every mark there is.
    @Test("The mark loads")
    @MainActor
    func iconResourceLoads() {
        #expect(LobeIconStore.image(named: Provider.newAPI.iconResource) != nil,
                "\(Provider.newAPI.iconResource).svg does not load")
    }

    private func assertMoney(_ actual: Double?, isCloseTo expected: Double) {
        guard let actual else {
            Issue.record("no figure")
            return
        }
        #expect(abs(actual - expected) < 0.000_001)
    }
}
