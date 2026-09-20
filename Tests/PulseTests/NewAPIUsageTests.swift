import Foundation
import Testing
@testable import Pulse

/// New API is the first provider here that is **somebody's own site** rather
/// than a vendor's, so everything about it begins with the address the reader
/// typed. These tests are about the two replies that come back from it, and
/// about the one figure in them that cannot be taken at face value.
///
/// Two of the fixtures are a live gateway's own bytes — its address is written
/// here as `ai.example.cn` — and the sentinel in them is the whole reason this
/// service has two modes.
@Suite("New API gateway")
struct NewAPIUsageTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(
            forResource: name, withExtension: "json", subdirectory: "Fixtures"
        ))
        return try Data(contentsOf: url)
    }

    private static func subscription(_ name: String) throws -> NewAPIUsageService.Subscription {
        try JSONDecoder().decode(NewAPIUsageService.Subscription.self, from: try fixture(name))
    }

    private static func spent(_ name: String = "newapi-usage") throws -> Double {
        try #require(try JSONDecoder().decode(NewAPIUsageService.Usage.self, from: try fixture(name)).spent)
    }

    // MARK: - The two replies

    /// The captured reply of a key issued with `unlimited_quota`. `new-api`
    /// forces all three `*_limit_usd` fields to this figure, so it is a
    /// **statement that there is no ceiling**, and reading it as one draws a
    /// ring pinned at zero for the life of the account.
    @Test("The captured unlimited key reads as the sentinel it is")
    func theSentinelIsNotACeiling() throws {
        let reply = try Self.subscription("newapi-subscription-unlimited")
        let hard = try #require(reply.hardLimitUSD)

        #expect(hard == 100_000_000)
        #expect(reply.softLimitUSD == 100_000_000)
        #expect(NewAPIUsageService.ceiling(fromHardLimitUSD: hard) == nil)
    }

    @Test("A gateway that states an allowance is measured against its own figure")
    func aStatedAllowanceIsACeiling() throws {
        let reply = try Self.subscription("newapi-subscription-stated")
        let ceiling = try #require(reply.hardLimitUSD.flatMap(NewAPIUsageService.ceiling(fromHardLimitUSD:)))

        #expect(ceiling == 20)
        #expect(NewAPIUsageService.ceiling(fromHardLimitUSD: 0) == nil)
        #expect(NewAPIUsageService.ceiling(fromHardLimitUSD: -5) == nil)
    }

    /// **`total_usage` is in cents.** Read straight, the captured reply is
    /// $710,014 rather than $7,100.14 — and the field is named as though it
    /// were money, so nothing but a test catches it.
    @Test("total_usage is a hundredth of the money it stands for")
    func usageArrivesInCents() throws {
        #expect(try Self.spent() == 7_100.144736)
        #expect(NewAPIUsageService.spent(fromUsageTotal: 0) == 0)
        #expect(NewAPIUsageService.spent(fromUsageTotal: .nan) == nil)
        // A negative total is not a negative spend.
        #expect(NewAPIUsageService.spent(fromUsageTotal: -100) == 0)
    }

    /// `billing.go` reports a lookup failure as **HTTP 200** with an `error`
    /// object and no figures. Absent has to stay absent: a spend read as zero
    /// is a ring at 0% and a balance that says the account is untouched.
    @Test("An error envelope is not a zero")
    func anErrorEnvelopeIsNotAZero() throws {
        let envelope = Data(#"{"error":{"message":"Unauthorized","type":"new_api_error"}}"#.utf8)

        let reply = try JSONDecoder().decode(NewAPIUsageService.Subscription.self, from: envelope)
        #expect(reply.hardLimitUSD == nil)
        #expect(reply.softLimitUSD == nil)

        let usage = try JSONDecoder().decode(NewAPIUsageService.Usage.self, from: envelope)
        #expect(usage.totalUsage == nil)
        #expect(usage.spent == nil)
    }

    // MARK: - The unit

    /// The site names its own display unit, and that is the only reason the
    /// money is printed in dollars rather than in a currency nobody stated.
    @Test("The status route names the unit the figures are in")
    func theSiteNamesItsOwnUnit() throws {
        // The fields a live gateway reported, trimmed to the
        // ones this reads.
        let status = Data(#"{"success":true,"data":{"quota_per_unit":500000,"quota_display_type":"USD","usd_exchange_rate":7.3}}"#.utf8)
        #expect(NewAPIUsageService.currency(fromStatus: status) == "USD")

        let yuan = Data(#"{"data":{"quota_display_type":"CNY"}}"#.utf8)
        #expect(NewAPIUsageService.currency(fromStatus: yuan) == "CNY")

        // Tokens are not a currency, and neither is a reply that says nothing.
        #expect(NewAPIUsageService.currency(fromStatus: Data(#"{"data":{"quota_display_type":"TOKENS"}}"#.utf8)) == nil)
        #expect(NewAPIUsageService.currency(fromStatus: Data(#"{"success":true}"#.utf8)) == nil)

        // And no unit means a plain number rather than an invented symbol.
        #expect(NewAPIUsageService.money(1_234.5, currency: nil) == "1,234.5")
        #expect(NewAPIUsageService.money(7_100.144736, currency: "USD") == "$7,100.14")
    }

    // MARK: - Where the denominator comes from

    /// The captured key, with no budget: a complete answer with nothing to
    /// measure it against, which is reported rather than drawn.
    @Test("An unlimited key with no budget draws no ring and says why")
    func unlimitedWithoutABudgetDrawsNothing() {
        let reading = NewAPIUsageService.reading(
            spent: 7_100.144736, hardLimitUSD: 100_000_000, currency: "USD", budget: nil
        )

        #expect(reading.windows.isEmpty)
        #expect(reading.state == .unavailable(.gatewayNoAllowance))
        #expect(reading.creditBalance == nil)
        #expect(reading.creditIsSpent == false)
    }

    /// A denominator the reader typed is theirs, and every promise the project
    /// makes about inferred percentages has to hold: the row says `of your
    /// budget`, `--json` flags it as estimated, and there is no reset or length
    /// because a ledger has neither.
    @Test("A budget is marked as the reader's, and never as the gateway's")
    func aBudgetIsTheReadersFigure() throws {
        let reading = NewAPIUsageService.reading(
            spent: try Self.spent(), hardLimitUSD: 100_000_000, currency: "USD", budget: 10_000
        )
        let window = try #require(reading.windows.first)

        #expect(reading.windows.count == 1)
        #expect(abs(window.usedFraction - 0.7100144736) < 0.000_001)
        #expect(window.estimate == .yourBudget)
        #expect(window.isEstimated)
        #expect(window.scope == nil)
        #expect(window.reportsLength == false)
        #expect(window.resetsAt == nil)
        #expect(window.elapsedFraction(at: Date()) == nil)
        // The figure that is shown is what is gone, and the row says so.
        #expect(reading.creditBalance == "$7,100.14")
        #expect(reading.creditIsSpent)
    }

    /// Where the gateway states a ceiling, nothing is inferred at all: the
    /// fraction is its own arithmetic on its own two figures, and the money is
    /// what is **left**.
    @Test("A stated ceiling beats a budget and infers nothing")
    func aStatedCeilingWins() throws {
        let stated = NewAPIUsageService.reading(spent: 5, hardLimitUSD: 20, currency: "USD", budget: nil)
        let window = try #require(stated.windows.first)

        #expect(window.usedFraction == 0.25)
        #expect(window.estimate == nil)
        #expect(window.isEstimated == false)
        #expect(stated.creditBalance == "$15.00")
        #expect(stated.creditIsSpent == false)

        // Both on offer: the gateway's figure is the one that is used.
        let both = NewAPIUsageService.reading(spent: 5, hardLimitUSD: 20, currency: "USD", budget: 100)
        #expect(both.windows.first?.usedFraction == 0.25)
        #expect(both.windows.first?.estimate == nil)
    }

    /// A budget of "inf" parses as a `Double` greater than zero, and an
    /// infinite denominator makes the fraction NaN — which `min`/`max`
    /// propagate rather than clamp, and which `Int(_:)` **traps** on.
    @Test("A budget that cannot be a denominator draws nothing, and never a NaN")
    func aBudgetMustBeAFigure() {
        for budget in [nil, 0, -5, .infinity, -.infinity, .nan] as [Double?] {
            let reading = NewAPIUsageService.reading(
                spent: 5, hardLimitUSD: 100_000_000, currency: "USD", budget: budget
            )
            #expect(reading.windows.isEmpty, "budget \(String(describing: budget))")
        }

        let window = NewAPIUsageService.windows(spent: .nan, ceiling: 10, budget: nil).first
        #expect(window?.usedFraction == 0)
    }

    /// Spending more than the figure the reader called a full tank is a real
    /// state — the key was topped up past it, or the reader was optimistic —
    /// and it is reported rather than clamped back to 100%.
    @Test("An overrun is reported rather than clamped away")
    func anOverrunIsReported() {
        let reading = NewAPIUsageService.reading(
            spent: 900, hardLimitUSD: 100_000_000, currency: nil, budget: 100
        )
        #expect(reading.windows.first?.usedFraction == 9)
        // No unit named by the site, so nothing is invented for it.
        #expect(reading.creditBalance == "900")
    }

    /// Nothing here claims the key is spent: `isExhausted` is the provider's
    /// verdict, and these two routes do not carry one.
    @Test("Spent is never inferred from the arithmetic")
    func spentIsNeverInferred() {
        let reading = NewAPIUsageService.reading(
            spent: 500, hardLimitUSD: 100, currency: "USD", budget: nil
        )
        #expect(reading.windows.first?.usedFraction == 5)
        #expect(reading.windows.first?.isExhausted == false)
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
            == "https://ai.example.cn/v1/dashboard/billing/subscription")
        #expect(NewAPIUsageService.usageURL(base).absoluteString
            == "https://ai.example.cn/v1/dashboard/billing/usage")
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
        // No "warn below" line: what this gateway reports is a **spend**, and a
        // money-left figure exists only where the gateway states a ceiling of
        // its own, so an alert compared against it would be a control that
        // cannot fire for the key most people are issued.
        #expect(provider.reportsSpendableBalance == false)
        // Which is also the answer to the other half of that pair — the two
        // questions are answered together in `UsageProvider` — and it is the
        // wrong answer for a spend on somebody else's servers. What it costs
        // is the *idle* cadence: with nothing local moving, a refresh is left
        // up to the half-hour ceiling rather than the five-minute one, and a
        // hover or a figure that moved brings it back to two minutes.
        #expect(provider.spendingIsWatchedLocally)
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
}
