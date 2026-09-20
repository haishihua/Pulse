import Foundation

/// Actions for the credential or tool that this account actually uses.
enum ConnectionRemedy: Equatable {
    case signIn
    case editCredential
    case readBrowser
    case connectStatusLine
    case openApp(String)
    case copyCommand(String)
    case retry
    case help

    static func forReason(_ reason: ProviderUsage.Unavailability, account: AccountKey) -> Self? {
        if !account.isPrimary,
           [.signedOut, .claudeLoginExpired, .signInRequired, .grokLoginExpired,
            .cursorLoginExpired, .cursorSignInRequired].contains(reason) {
            return .signIn
        }
        switch reason {
        case .loading, .awaitingResponse: return nil
        case .notConnected: return .connectStatusLine
        case .claudeSignInRequired, .claudeLoginExpired: return .copyCommand("claude auth login")
        case .signInRequired: return .copyCommand("codex login")
        case .grokSignInRequired, .grokLoginExpired: return .copyCommand("grok")
        case .volcengineSignInRequired: return .copyCommand("arkcli auth login")
        case .claudeDesktopNotSignedIn, .claudeDesktopSessionExpired: return .openApp("Claude")
        case .cursorSignInRequired, .cursorLoginExpired: return .openApp("Cursor")
        case .antigravityNotRunning, .antigravityNotAnswering: return .openApp("Antigravity")
        // The remedy for both is the same thing: start it. A plan it has never
        // recorded is one sign-in away, and opening the app is the step before
        // that either way.
        case .devinAppMissing, .devinPlanUnread: return .openApp("Devin")
        case .notSignedIn, .signedOut: return .signIn
        case .apiKeyMissing, .apiKeyRefused, .devinOrganizationMissing: return .editCredential
        // The address and the token are typed into the same pane, so the same
        // remedy — open it and fill the blank in — covers all three. Worth its
        // own button rather than none: a fresh install has nothing in either
        // field and no way to guess what belongs in them.
        case .gatewayAddressMissing, .gatewayTokenMissing,
             .gatewayTokenRefused: return .editCredential
        case .ollamaSessionMissing, .ollamaSessionExpired,
             .xiaomiSessionMissing, .xiaomiSessionExpired: return .readBrowser
        case .claudeDesktopKeyRefused, .unreachable, .rateLimited, .serverError,
             .codexServerFailed: return .retry
        // Setup help opens this provider's own page, and it is the page that
        // describes the two settings the message names.
        case .codexNotInstalled, .volcengineCLIMissing, .noLimitsReported,
             .grokBotNotIncluded, .zaiNoCodingPlan, .xiaomiNoCodingPlan,
             .ollamaPageChanged, .unreadableReply:
            return .help
        }
    }

    var title: String {
        switch self {
        case .signIn: .localized("Sign in again…")
        case .editCredential: .localized("Edit credential")
        case .readBrowser: .localized("Read from browser")
        case .connectStatusLine: .localized("Connect status line")
        case .openApp(let name): .localized("Open \(name)")
        case .copyCommand: .localized("Copy login command")
        case .retry: .localized("Retry")
        case .help: .localized("Setup help")
        }
    }

    static func helpURL(for provider: Provider) -> URL {
        let page: String = switch provider {
        case .claudeCode: "claude-code"
        case .codex: "codex"
        case .antigravity: "antigravity"
        case .cursor: "cursor"
        case .openCodeGo: "opencode-go"
        case .kimiCode: "kimi-code"
        case .ollamaCloud: "ollama-cloud"
        case .xiaomiMiMo: "xiaomi-coding-plan"
        case .zai, .glmCoding: "zai"
        case .minimax, .minimaxCN: "minimax"
        case .copilot: "copilot"
        case .grok: "grok"
        case .grokBot: "grok-bot"
        case .volcengine: "volcengine"
        case .commandCode: "command-code"
        case .deepSeek: "deepseek"
        case .devin: "devin"
        case .newAPI: "new-api"
        }
        return URL(string: "https://github.com/qunqin24/Pulse/blob/main/Docs/providers/\(page).md")!
    }
}
