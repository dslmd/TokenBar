# TokenBar redesign: direction and screen specs

Written on the first Mac build, after the original design documents turned out not to exist. It is the
brief the redesign is built against, and it records the decisions behind it.

## 1. What is wrong today (audit, from real renders)

- **Popover is a wall of cards.** Every account is a 300 pt card (stats, split bar, chart, all quota bars).
  With five providers the useful facts (which quota is close to running out, how much was used today) are
  scattered over four screens of scrolling. Numbers repeat (section total and card total).
- **No hierarchy.** Header spends its space on the word "TokenBar". The single most useful number (today's
  total) and the single most urgent fact (highest quota) are nowhere at the top.
- **No detail level.** Overview and detail are the same view, so both are compromised.
- **Settings feel like a form dump.** Email shown twice per account, full managed paths, a name field that
  grabs focus and selects its text on open, an always-visible explanation under every sign-in button,
  checkboxes and switches mixed, tab control drawn as a white box in dark snapshots.
- **First launch has no guidance.** A new user sees either a spinner or a list of four sign-in buttons.
- **No notifications.** The whole point (not hitting a quota by surprise) needs the user to keep looking.

## 2. Direction

Feel like a menu bar extra Apple would ship (Battery, Wi-Fi, Focus, Screen Time): calm, glanceable,
native controls, system materials, semantic colors, SF Symbols, SF Pro, no custom chrome.

1. **Glance first.** Top of the popover answers "how much today" and "am I close to a limit" in one look.
2. **One row per account** in the overview; everything else one click away in a detail page.
3. **Color means state, only.** Accent for normal, orange for elevated (75 %+), red for critical (90 %+),
   gray for stale. Thresholds come from `QuotaLevel` in TokenBarCore. Never color-only: always a number too.
4. **Native everything.** System window material (the popover is translucent glass on macOS 26+; never paint
   an opaque window background inside it), grouped `Form`s in settings, standard toolbar-tab settings window,
   standard notifications.
5. **Quiet copy.** English, sentence case, no exclamation marks, short. Explanations go in footers or help
   tags, not under every control.

## 3. Shared tokens

| Token | Value |
|---|---|
| Popover width | 340 pt |
| Popover max scroll height | 520 pt (list), detail page the same |
| Outer padding | 14 pt horizontal, 12 pt vertical |
| Group corner radius | 10 pt, `.continuous` |
| Group fill | `Color.primary.opacity(0.05)` (light) / same token works in dark; hover row `0.08` |
| Row height | min 44 pt, 10 pt vertical padding, 12 pt horizontal |
| Hairline between rows | `Divider()` inset 12 pt leading |
| Hero number | `.system(size: 28, weight: .semibold, design: .rounded)`, `.monospacedDigit()` |
| Row primary | `.body` (13 pt) medium; numbers `.monospacedDigit()` |
| Secondary | `.callout`/`.subheadline` + `.secondary`; tertiary info `.caption` + `.secondary` |
| Section label | `.subheadline.weight(.semibold)`, `.secondary`, provider SF Symbol before it |
| Bars | quota bar 5 pt tall capsule (track `primary.opacity(0.1)`); mini bar in rows 3 pt |
| Motion | 0.2 s ease-in-out, nothing when Reduce Motion is on |

## 4. Screens

### 4.1 Menu bar label
- Template SF Symbol + optional number, 13 pt. Symbol: `chart.bar.fill` normally, `exclamationmark.triangle.fill`
  when any current quota is at 90 %+.
- Number: setting "Show in menu bar: Tokens / Highest quota" (`MenuBarMetric`), already computed by
  `model.menuBarTitle`. Icon only when the number is turned off.

### 4.2 Popover (menu bar window), overview
```
┌──────────────────────────────────────────┐
│ Today                          ⟳   ⋯     │  .subheadline secondary; refresh + "more" menu
│ 1.6M tokens                              │  hero number + " tokens" (.title3, secondary)
│ ● Weekly 93% · Claude Code · resets 2 d  │  peak quota line, dot/number tinted by level
├──────────────────────────────────────────┤
│ ✦ Claude Code                     1.5M   │  section label, provider today total (secondary)
│ ╭──────────────────────────────────────╮ │
│ │ alex@example.com              1.4M › │ │  row: name, today tokens, chevron
│ │ Weekly 93% · resets in 2 days        │ │  peak window summary (caption), tinted percent
│ │ ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬░░ │ │  3 pt mini bar of that window
│ ├──────────────────────────────────────┤ │
│ │ sam.rivera@example.com         148K ›│ │
│ │ ⚠ Sign-in expired. Run claude once…  │ │  attention message replaces the quota line
│ ╰──────────────────────────────────────╯ │
│ …Codex, Gemini CLI, Muse, Muse Code      │
├──────────────────────────────────────────┤
│ Updated 1 min ago                        │  footer, .caption secondary (no Quit button here)
└──────────────────────────────────────────┘
```
- "More" (`ellipsis.circle`) menu: Refresh (⌘R), Settings… (⌘,), divider, Quit TokenBar (⌘Q). Keyboard
  shortcuts must work while the window is open.
- Muse rows: plan name instead of tokens on the right; quota line from its weekly window.
- Muse Code (no quota): second line "Last active 1 day ago".
- Rows are buttons: click opens the detail page; hover highlight.
- Peak line omitted when no account has quota; header then shows "No quota data" nothing at all.
- States: loading row ("Reading…" with small spinner), scanning (centered spinner + "Looking for accounts…"),
  no accounts (icon, "No accounts yet", one line, primary button "Set up TokenBar…" which opens onboarding,
  secondary "Open Settings"), all turned off ("All accounts are turned off", "Open Settings").
- Collapsible sections are dropped (rows are compact enough).

### 4.3 Account detail (inside the popover)
```
┌──────────────────────────────────────────┐
│ ‹ Claude Code                            │  back (click or Esc), slides in from the right
│ alex@example.com                         │  .title3 semibold
│ Max · Example Labs                       │  identity line, secondary
│ ╭────────╮ ╭────────╮ ╭────────╮         │
│ │ 1.4M   │ │ 12M    │ │ 21M    │         │  three stat tiles: Today / Last 7 days / This month
│ │ Today  │ │ 7 days │ │ Month  │         │
│ ╰────────╯ ╰────────╯ ╰────────╯         │
│ Last 7 days                              │
│  ▇  █  ▁  ▁  █  ▆  ▅                     │  64 pt chart, today in accent, others accent 35 %
│  S  M  T  W  T  F  S                     │  help tag per bar with the exact count
│ Input 904K · Output 466K · Cache 18M     │  split bar 5 pt + legend
│ Quota                                    │  section label
│  5-hour          resets in 2 hr    62%   │
│  ▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬▬░░░░░░░░░░░░░░░░       │
│  Weekly          resets in 2 days  93%   │
│  From online check, 2 min ago            │  caption
│ ⚠ problem line + action (Sign in again)  │  when relevant
│ [Account Settings…]                      │  opens settings on the accounts tab
└──────────────────────────────────────────┘
```
- Muse detail: plan, weekly bar, tokens left, additional tokens, "From muse.ai, 3 min ago", Sign in again.
- Muse Code: no quota section.

### 4.4 First-launch setup (onboarding window)
- Own window, 560 × 460 pt, titled, closable, centered, shown on first launch (`model.needsOnboarding`) and
  from the popover's empty state. Closing it counts as done (`model.completeOnboarding()`).
- Three pages, page dots at the bottom center, buttons bottom right (Back as plain, Continue/Done as default
  `.borderedProminent`), Esc closes.
  1. **Welcome.** App icon 96 pt, "Welcome to TokenBar", one-line subtitle, three feature rows (SF Symbol in
     accent, title, one line): finds your accounts; warns before you hit a limit; reads logs on this Mac.
  2. **Your accounts.** Live list of what detection found, grouped by provider with identity lines; spinner
     while scanning; per provider a "Sign in…" button for adding an account (CLI sign-in progress shown
     inline from `model.signInPhases`; Muse opens its web sign-in). Empty state explains what to do.
  3. **Quota and notifications.** Switch "Check quota online" with a short honest footer about what is sent
     where; switch "Notify me before I hit a limit" + threshold picker; turning it on asks for notification
     permission. Final note: "TokenBar lives in the menu bar" with the actual label rendered as a hint.

### 4.5 Settings window
- Real macOS settings look: `NSTabViewController` with `.toolbar` tab style (icons + labels in the toolbar),
  window title follows the tab, width 620 pt, height fits each tab (animate between tabs). Tabs: General
  (`gearshape`), Accounts (`person.2`), Notifications (`bell.badge`).
- All tabs are `Form` with `.formStyle(.grouped)`.
- **General**: Startup (Open at login); Menu bar (Show: Tokens / Highest quota; Provider: All / each;
  Period; Include cache tokens; Show number next to the icon; live preview of the label in the footer);
  Refresh (interval); Online quota (switch, explanation in the footer).
- **Accounts**: header row "TokenBar finds accounts on this Mac automatically." + Rescan button with spinner.
  One section per provider (header: symbol + name; footer: provider note). Row: status dot, name (plain text,
  not an editable field), identity/plan as subtitle (no duplicated email), trailing switch (small) and a
  `…` menu: Rename…, Online quota (checkmark item), Copy shell alias, Show in Finder, Change folder…, Sign in
  again…, Remove…. Problems shown under the row in orange caption. Path shown only as a help tag and in the
  menu. Last row of each section: "Sign in to another account…" (CLI progress inline: spinner + hint + Cancel;
  failure: message + Try again). "Add folder manually…" moves into a sheet opened from the section's menu.
  `show(model:tab:accountID:)` scrolls to and briefly highlights the account.
- **Notifications**: Quota alerts (switch + threshold picker 75/90/95 %); Sign-in problems (switch); state of
  the system permission (not determined: "Allow notifications" button; denied: explanation + "Open System
  Settings"; unavailable in development builds: one line).

### 4.6 Notifications
- System banners via `NotificationService`, texts from `QuotaAlerts` (Core, tested):
  title "Weekly quota at 93%", subtitle "Claude Code · alex@example.com", body "Resets in 2 days.";
  sign-in: "Sign-in needs attention" / provider · account / the problem sentence.
- Grouped per account (thread identifier), one per window cycle, remembered across relaunches.

## 5. Work split (no two agents touch the same file)

| Area | Owner | Files |
|---|---|---|
| Core logic, model, app wiring, notifications service, snapshot runner | lead | `Sources/TokenBarCore/**` (existing files), `AppModel.swift`, `TokenBarApp.swift`, `Notifications/**`, `SnapshotRunner.swift`, `Formatting.swift` |
| Popover, account detail, menu bar label | agent A | `Popover/**`, `MenuBar/**`, `Snapshots/PopoverShots.swift` |
| Settings window | agent B | `Settings/**`, `Snapshots/SettingsShots.swift` |
| Onboarding | agent C | `Onboarding/**`, `Snapshots/OnboardingShots.swift` |

Agents may add new files inside their own folder, new Core files under `Sources/TokenBarCore/UI<Area>/` and
new test files `Tests/TokenBarCoreTests/<Area>*Tests.swift` for any decision logic. They may add model API
only as an extension in their own folder (`Popover/AppModel+Popover.swift` etc.), never edit shared files.

Contracts between areas (already in place, keep the signatures):
- `SettingsWindowController.shared.show(model:)` and `show(model:tab:accountID:)`, `SettingsTab`.
- `OnboardingWindowController.shared.show(model:)` / `close()`.
- `NotificationService.shared` (`authorization`, `requestAuthorization`, `refreshAuthorization`,
  `openSystemSettings`, `setAuthorizationForSnapshot`).
- `model.completeOnboarding()`, `model.needsOnboarding`, `model.quotaWindows(for:)`, `model.peakWindow(for:)`,
  `model.attentionMessage(for:)`, `model.todayTotal`.

## 6. Verification

- `scripts/snapshot.sh --snapshot-only <prefix>` renders demo data to `build/snapshots/` in light and dark;
  every changed screen is looked at in both. Menu bar window shots use `menuBarWindow: true`.
- The popover is checked once more in the running app (`scripts/dev-run.sh --demo`), because the real window
  is translucent and sizes itself differently from an offscreen render.
