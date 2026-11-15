import XCTest
@testable import TokenBarCore

final class OnboardingFlowTests: XCTestCase {
    func testPageOrderAndButtons() {
        XCTAssertEqual(OnboardingPage.allCases, [.welcome, .accounts, .alerts])
        XCTAssertTrue(OnboardingPage.welcome.isFirst)
        XCTAssertNil(OnboardingPage.welcome.previous)
        XCTAssertEqual(OnboardingPage.welcome.next, .accounts)
        XCTAssertEqual(OnboardingPage.accounts.previous, .welcome)
        XCTAssertTrue(OnboardingPage.alerts.isLast)
        XCTAssertNil(OnboardingPage.alerts.next)
        XCTAssertEqual(OnboardingPage.welcome.primaryButtonTitle, "Continue")
        XCTAssertEqual(OnboardingPage.accounts.primaryButtonTitle, "Continue")
        XCTAssertEqual(OnboardingPage.alerts.primaryButtonTitle, "Done")
    }

    func testSignInStateFromCLIPhases() {
        func make(_ phase: LoginPhase?) -> OnboardingSignInState {
            OnboardingSignInState.make(signIn: .cli, unavailableReason: nil, phase: phase, isWebSignInOpen: false)
        }
        XCTAssertEqual(make(nil), .available)
        XCTAssertEqual(make(.cancelled), .available)
        XCTAssertEqual(make(.locatingCLI), .inProgress(hint: nil))
        XCTAssertEqual(make(.waitingForUser(hint: "Continue in your browser.")), .inProgress(hint: "Continue in your browser."))
        XCTAssertEqual(make(.failed(message: "Not installed.")), .failed(message: "Not installed."))
        XCTAssertEqual(make(.succeeded(homePath: "/tmp/x")), .succeeded)
        XCTAssertFalse(make(.failed(message: "x")).showsButton)
        XCTAssertTrue(make(nil).showsButton)
        XCTAssertFalse(make(.locatingCLI).showsButton)
    }

    func testSucceededGivesWayOnceTheAccountIsListed() {
        let done = LoginPhase.succeeded(homePath: "/Users/a/Library/Application Support/TokenBar/accounts/claude-1A2B")
        XCTAssertEqual(OnboardingSignInState.make(signIn: .cli, unavailableReason: nil, phase: done, isWebSignInOpen: false,
                                                  accountRegistered: false), .succeeded)
        XCTAssertEqual(OnboardingSignInState.make(signIn: .cli, unavailableReason: nil, phase: done, isWebSignInOpen: false,
                                                  accountRegistered: true), .available)
        let home = "/Users/a/Library/Application Support/TokenBar/accounts/claude-1A2B/"
        XCTAssertTrue(OnboardingSignInState.isRegistered(homePath: home, dataPaths: ["/x/.claude", "~/Library/Application Support/TokenBar/accounts/claude-1A2B/.claude"]))
        XCTAssertFalse(OnboardingSignInState.isRegistered(homePath: home, dataPaths: ["/x/.claude", "/y/claude-1A2"]))
        XCTAssertFalse(OnboardingSignInState.isRegistered(homePath: "/", dataPaths: ["/x"]))
    }

    func testRunningProviders() {
        let phases: [String: LoginPhase] = [
            "codex": .waitingForUser(hint: "x"), "claude": .locatingCLI, "gemini": .failed(message: "x"),
            "other": .succeeded(homePath: "/h"), "gone": .cancelled,
        ]
        XCTAssertEqual(OnboardingSignInState.runningProviders(phases), ["claude", "codex"])
    }

    func testWebSignInMessageReadsAsAFailure() {
        XCTAssertEqual(OnboardingSignInState.make(signIn: .web, unavailableReason: nil, phase: nil, isWebSignInOpen: false,
                                                  webSignInMessage: "Could not save."), .failed(message: "Could not save."))
        XCTAssertEqual(OnboardingSignInState.make(signIn: .web, unavailableReason: nil, phase: nil, isWebSignInOpen: true,
                                                  webSignInMessage: "Could not save."), .waitingForWeb)
        XCTAssertFalse(OnboardingSignInState.failed(message: "x").showsButton)
    }

    func testProblemTextSplitsTheInstallCommand() {
        let parsed = OnboardingProblemText.parse("Gemini CLI is not installed. Install it with: npm install -g @google/gemini-cli")
        XCTAssertEqual(parsed.command, "npm install -g @google/gemini-cli")
        XCTAssertEqual(parsed.text, "Gemini CLI is not installed. Install it with this command in Terminal:")
        XCTAssertEqual(OnboardingProblemText.parse("Could not open Terminal."), OnboardingProblemText(text: "Could not open Terminal.", command: nil))
        XCTAssertNil(OnboardingProblemText.parse("Install it with: ").command)
    }

    func testNotFoundHeader() {
        XCTAssertNil(OnboardingAccounts.notFoundHeader(foundAny: false, isScanning: false))
        XCTAssertEqual(OnboardingAccounts.notFoundHeader(foundAny: true, isScanning: true), "Other tools")
        XCTAssertEqual(OnboardingAccounts.notFoundHeader(foundAny: true, isScanning: false), "Not found on this Mac")
    }

    func testSignInStateForWebAndUnavailable() {
        XCTAssertEqual(OnboardingSignInState.make(signIn: .web, unavailableReason: nil, phase: nil, isWebSignInOpen: true), .waitingForWeb)
        XCTAssertEqual(OnboardingSignInState.make(signIn: .web, unavailableReason: nil, phase: nil, isWebSignInOpen: false), .available)
        XCTAssertEqual(OnboardingSignInState.make(signIn: .cli, unavailableReason: "No CLI.", phase: .locatingCLI, isWebSignInOpen: false),
                       .unavailable(reason: "No CLI."))
        if case .unavailable = OnboardingSignInState.make(signIn: .none, unavailableReason: nil, phase: nil, isWebSignInOpen: false) {
        } else {
            XCTFail("a provider without sign-in has no button")
        }
    }

    func testGroupsFollowCatalogAndKeepEmptyProvidersWithoutSignIn() {
        let catalog = ProviderCatalog.default
        let claude = Account(providerID: "claude", name: "alex@example.com", dataPath: "/x/.claude")
        let work = Account(providerID: "claude", name: "Work", dataPath: "/x/.claude-work", isEnabled: false)
        let identities = [
            claude.id: AccountIdentity(email: "alex@example.com", plan: "max", organization: "Example Labs", isSignedIn: true),
            work.id: AccountIdentity(email: "sam@example.com", isSignedIn: true),
        ]
        let groups = OnboardingAccounts.groups(catalog: catalog, accounts: [claude, work], identities: identities) { info in
            info.capabilities.signIn == .none ? .unavailable(reason: "no") : .available
        }
        XCTAssertEqual(groups.map(\.id), catalog.providers.map(\.id))
        XCTAssertEqual(Array(groups.map(\.id).prefix(5)), ["claude", "codex", "gemini", ProviderCatalog.museAIID, "muse"])
        XCTAssertEqual(groups[4].signIn.unavailableReason, "no")
        XCTAssertEqual(groups[0].accounts.map(\.title), ["alex@example.com", "Work"])
        XCTAssertEqual(groups[0].accounts[0].subtitle, "Max · Example Labs")
        XCTAssertEqual(groups[0].accounts[1].subtitle, "sam@example.com · Turned off")
        XCTAssertTrue(groups[1].accounts.isEmpty)
        let split = OnboardingAccounts.split(groups)
        XCTAssertEqual(split.found.map(\.id), ["claude"])
        XCTAssertEqual(split.notFound.map(\.id), Array(catalog.providers.map(\.id).dropFirst()))

        let muse = Account(providerID: "muse", name: "Default", dataPath: "/x/muse")
        let withMuse = OnboardingAccounts.groups(catalog: catalog, accounts: [muse], identities: [:]) { _ in .unavailable(reason: "no") }
        XCTAssertEqual(OnboardingAccounts.split(withMuse).found.map(\.id), ["muse"])
        XCTAssertNil(withMuse.first { $0.id == "muse" }?.accounts[0].subtitle)
    }

    func testSubtitleSaysSignedInWhenNothingElseIsKnown() {
        let account = Account(providerID: "gemini", name: "Default", dataPath: "/x")
        XCTAssertEqual(OnboardingAccounts.subtitle(for: account, identity: AccountIdentity(isSignedIn: true)), "Signed in")
        XCTAssertNil(OnboardingAccounts.subtitle(for: account, identity: nil))
    }

    func testStatus() {
        XCTAssertEqual(OnboardingAccounts.status(accountCount: 0, isScanning: true, hasScanned: false), .searching)
        XCTAssertEqual(OnboardingAccounts.status(accountCount: 0, isScanning: false, hasScanned: false), .searching)
        XCTAssertEqual(OnboardingAccounts.status(accountCount: 0, isScanning: false, hasScanned: true), .empty)
        XCTAssertEqual(OnboardingAccounts.status(accountCount: 3, isScanning: true, hasScanned: true), .found(count: 3, stillScanning: true))
        XCTAssertTrue(OnboardingAccountsStatus.found(count: 1, stillScanning: false).headline.contains("1 account."))
        XCTAssertTrue(OnboardingAccountsStatus.found(count: 2, stillScanning: false).headline.contains("2 accounts."))
    }

    func testAlertThreshold() {
        XCTAssertNil(OnboardingAlerts.threshold(enabled: false, remembered: 95))
        XCTAssertEqual(OnboardingAlerts.threshold(enabled: true, remembered: 95), 95)
        XCTAssertEqual(OnboardingAlerts.threshold(enabled: true, remembered: nil), AppSettings.defaultQuotaAlertThreshold)
        XCTAssertEqual(OnboardingAlerts.threshold(enabled: true, remembered: 42), AppSettings.defaultQuotaAlertThreshold)
    }

    func testPermissionIsRequestedForTheDefaultChoice() {
        XCTAssertTrue(OnboardingAlerts.shouldRequestPermission(threshold: 90, permissionNotDetermined: true))
        XCTAssertFalse(OnboardingAlerts.shouldRequestPermission(threshold: nil, permissionNotDetermined: true))
        XCTAssertFalse(OnboardingAlerts.shouldRequestPermission(threshold: 90, permissionNotDetermined: false))
    }
}
