import Foundation
import XCTest
@testable import TokenBarCore

final class SettingsRulesTests: XCTestCase {
    func testSubtitleDropsTheEmailWhenItIsTheName() {
        let identity = AccountIdentity(email: "alex@example.com", plan: "max", organization: "Example Labs", isSignedIn: true)
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "alex@example.com", identity: identity), "Max · Example Labs")
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "ALEX@example.com ", identity: identity), "Max · Example Labs")
    }

    func testSubtitleKeepsTheEmailForRenamedAccounts() {
        let identity = AccountIdentity(email: "alex@example.com", plan: "plus", isSignedIn: true)
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "Work", identity: identity), "alex@example.com · Plus")
    }

    func testSubtitleFallbacks() {
        // Signed in, nothing else known.
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "Default", identity: AccountIdentity(isSignedIn: true)), "Signed in")
        // Email equals the name and nothing else: fall back to the origin.
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "a@example.com", identity: AccountIdentity(email: "a@example.com", isSignedIn: true),
                                                     origin: .detected), "Detected")
        // Muse: plan read online.
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "Muse Maximum", identity: nil, webPlan: "Maximum"), "Maximum plan")
        XCTAssertEqual(SettingsRules.accountSubtitle(name: "x", identity: nil, webPlan: "Free plan"), "Free plan")
        XCTAssertNil(SettingsRules.accountSubtitle(name: "x", identity: nil))
    }

    func testHelpAndPaths() {
        XCTAssertEqual(SettingsRules.shortPath("/Users/me/.claude", home: "/Users/me"), "~/.claude")
        XCTAssertEqual(SettingsRules.shortPath("/Users/me", home: "/Users/me"), "~")
        XCTAssertEqual(SettingsRules.shortPath("/Users/meme/x", home: "/Users/me"), "/Users/meme/x")
        XCTAssertEqual(SettingsRules.accountHelp(origin: .detected, path: "/Users/me/.codex", home: "/Users/me"), "Detected · ~/.codex")
        XCTAssertEqual(SettingsRules.accountHelp(origin: .signedIn, path: "", home: "/Users/me"), "Signed in here")
        XCTAssertEqual(SettingsRules.accountHelp(origin: nil, path: nil, home: "/Users/me"), "Added manually")
    }

    func testRenameValidation() {
        XCTAssertEqual(SettingsRules.validatedName("  Work  ", current: "alex@example.com"), "Work")
        XCTAssertNil(SettingsRules.validatedName("   ", current: "a"))
        XCTAssertNil(SettingsRules.validatedName("a", current: "a"))
        XCTAssertEqual(SettingsRules.validatedName(String(repeating: "x", count: 200), current: "a")?.count, 80)
    }

    func testTokenOptionsOnlyApplyToTokens() {
        XCTAssertTrue(SettingsRules.tokenOptionsApply(.tokens))
        XCTAssertFalse(SettingsRules.tokenOptionsApply(.peakQuota))
        XCTAssertEqual(SettingsRules.metricTitle(.peakQuota), "Highest quota")
    }

    func testRefreshChoices() {
        XCTAssertEqual(SettingsRules.refreshChoices(current: 60), [15, 30, 60, 120, 300])
        XCTAssertEqual(SettingsRules.refreshChoices(current: 90), [15, 30, 60, 90, 120, 300])
        XCTAssertEqual(SettingsRules.refreshTitle(15), "15 seconds")
        XCTAssertEqual(SettingsRules.refreshTitle(60), "1 minute")
        XCTAssertEqual(SettingsRules.refreshTitle(300), "5 minutes")
        XCTAssertEqual(SettingsRules.refreshTitle(90), "90 seconds")
    }

    func testQuotaThreshold() {
        XCTAssertFalse(SettingsRules.quotaAlertsOn(nil))
        XCTAssertTrue(SettingsRules.quotaAlertsOn(75))
        XCTAssertEqual(SettingsRules.thresholdPickerValue(nil), AppSettings.defaultQuotaAlertThreshold)
        XCTAssertEqual(SettingsRules.thresholdPickerValue(95), 95)
        XCTAssertEqual(SettingsRules.thresholdPickerValue(80), 75)
        XCTAssertEqual(SettingsRules.thresholdPickerValue(99), 95)
        XCTAssertEqual(SettingsRules.threshold(afterToggle: true, current: nil), 90)
        XCTAssertNil(SettingsRules.threshold(afterToggle: false, current: 75))
    }

    func testPermissionIsAskedOnlyWhenTurningOnAndNotAskedBefore() {
        XCTAssertTrue(SettingsRules.shouldAskForPermission(turningOn: true, permissionNotDetermined: true))
        XCTAssertFalse(SettingsRules.shouldAskForPermission(turningOn: false, permissionNotDetermined: true))
        XCTAssertFalse(SettingsRules.shouldAskForPermission(turningOn: true, permissionNotDetermined: false))
    }

    func testWindowHeightIsClamped() {
        XCTAssertEqual(SettingsRules.windowContentHeight(ideal: 412.2), 413)
        XCTAssertEqual(SettingsRules.windowContentHeight(ideal: 10), 240)
        XCTAssertEqual(SettingsRules.windowContentHeight(ideal: 5000), 640)
        XCTAssertEqual(SettingsRules.windowContentHeight(ideal: .infinity), 240)
    }

    func testProblemsShareOneTone() {
        XCTAssertEqual(SettingsRules.statusTone(.warning), .problem)
        XCTAssertEqual(SettingsRules.statusTone(.error), .problem)
        XCTAssertEqual(SettingsRules.statusTone(.ok), .ok)
        XCTAssertEqual(SettingsRules.statusTone(.disabled), .inactive)
        XCTAssertEqual(SettingsRules.statusTone(.unknown), .inactive)
    }

    func testNoAccountsRow() {
        XCTAssertTrue(SettingsRules.showsNoAccountsRow(accountCount: 0, hasScanned: true, isScanning: false, hasAddButton: false))
        // While scanning, or before the first scan, TokenBar does not know yet.
        XCTAssertFalse(SettingsRules.showsNoAccountsRow(accountCount: 0, hasScanned: false, isScanning: true, hasAddButton: false))
        XCTAssertFalse(SettingsRules.showsNoAccountsRow(accountCount: 0, hasScanned: true, isScanning: true, hasAddButton: false))
        // A sign-in or add button follows.
        XCTAssertFalse(SettingsRules.showsNoAccountsRow(accountCount: 0, hasScanned: true, isScanning: false, hasAddButton: true))
        XCTAssertFalse(SettingsRules.showsNoAccountsRow(accountCount: 2, hasScanned: true, isScanning: false, hasAddButton: false))
    }

    func testSignInFailureSplitsTheCommand() {
        let parts = SettingsRules.signInFailureText("Gemini CLI is not installed. Install it with: npm install -g @google/gemini-cli")
        XCTAssertEqual(parts.sentence, "Gemini CLI is not installed. Install it with:")
        XCTAssertEqual(parts.command, "npm install -g @google/gemini-cli")
        let newline = SettingsRules.signInFailureText("Codex CLI is not installed. Install it with:\nnpm install -g @openai/codex")
        XCTAssertEqual(newline.command, "npm install -g @openai/codex")
        // Plain sentences stay whole, a colon included.
        let plain = SettingsRules.signInFailureText("Sign-in failed: The browser window was closed.")
        XCTAssertEqual(plain.sentence, "Sign-in failed: The browser window was closed.")
        XCTAssertNil(plain.command)
        XCTAssertNil(SettingsRules.signInFailureText("The sign-in timed out. Try again.").command)
    }

    func testTokenOptionsNeedTheNumber() {
        XCTAssertTrue(SettingsRules.tokenOptionsApply(.tokens, showsNumber: true))
        XCTAssertFalse(SettingsRules.tokenOptionsApply(.tokens, showsNumber: false))
        XCTAssertFalse(SettingsRules.tokenOptionsApply(.peakQuota, showsNumber: true))
    }
}
