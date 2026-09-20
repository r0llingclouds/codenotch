# Personal usage dashboard and widgets

This fork adds a native SwiftUI dashboard and WidgetKit widgets to Codenotch. The background app reads
provider usage; the widget extension only receives normalized quota windows,
balances, status and measurement dates. Upstream Codenotch remains MIT licensed.

## Native app

Open Codenotch from Applications or Spotlight to see all nine services in one
resizable window. Select a card to open its details alongside the overview:
every reported quota, balance, reset date and last measurement. Unavailable or
stale readings stay explicitly marked. The app only names a plan when the
provider supplies it, and explains the scope of each service's readings.
When reported, Fable appears first on Claude's overview card, followed by the
session and all-model weekly allowance. Fable's percentage is highlighted in
Claude's accent color; it is visible without opening the details sidebar.

Use **Refresh** (⌘R) for all providers, **Refresh reading** for the selected one,
or **Manage accounts** to open the existing account settings. The menu bar's
**Open AI Usage** (⌘1) also brings the dashboard forward. A widget card opens
that service's details; the widget background opens the overview.

Closing the window (⌘W) leaves usage collection and widgets running. The Dock
icon remains while the dashboard or Settings is open, then returns to the
chosen app-presence setting. Opening the dashboard never adds another polling
loop: the app and widgets share the same store and readings.

## Widgets

- **All AI usage** (large): Codex, Claude, Cursor, Kimi, GLM, DeepSeek, Gemini chat,
  NotebookLM and Google Flow.
- **Provider usage** (small or medium): choose one provider in Edit Widget.
- **Google AI Pro** (medium): three separate meters for Gemini chat, NotebookLM
  and Flow. Antigravity and Gemini API quotas do not represent these products.

The overview displays all nine providers in a three-column grid.
Its compact header shows only the title; the branding and aggregate readiness
counter are omitted so the usage cards have more vertical space.
The widget design uses a dark blue background, provider marks, compact colored
cards and larger usage figures. Individual provider widgets use a circular main
meter; the small size also retains the second quota, and the medium size shows
up to three. Credit balances remain amounts rather than percentage gauges.
Missing and stale readings keep their explicit status.

The floating notch is hidden by default in this fork. Codenotch remains in the
menu bar for the dashboard, sign-in, refresh and settings. Close the windows to leave collection
running. Quit the app to stop it. No login item is installed automatically.

## Build and install

Install Xcode and accept its SDK license, then:

```sh
brew install xcodegen
make build
make test
make install
```

The personal-widgets GitHub Actions workflow also tests the app and produces
`Codenotch-Widgets.zip`. Builds are ad-hoc signed for local use, not notarized
releases. This fork uses `com.r0llingclouds.codenotch`, so its preferences and
WidgetKit extension are distinct from upstream. Upstream automatic updates are
disabled so they cannot overwrite the fork. The personal app does not link the
Sparkle framework; this also avoids its Team ID mismatch in ad-hoc builds.
Update by rebuilding this checkout.

Open Codenotch once. In macOS, right-click the desktop, choose **Edit Widgets**,
search **Codenotch**, then add the desired widget. The same widgets work in
Notification Center. Right-click Provider usage and choose **Edit Widget** to
change its provider.

## Connecting providers

Codex, Claude and Cursor use upstream's local credential discovery. Cursor
reads the account signed into the editor and shows its reported Auto, API and
on-demand allowances. The overview displays the first two meters; the medium
provider widget can show three. The OpenAI meter
measures **Codex usage on your ChatGPT plan**, not ChatGPT web chat activity.
Kimi reads the managed Kimi Code login, including the current global `.ai`
region and environment-specific credential file. Its current 5h and monthly
ratios take priority over legacy counters. Codenotch automatically renews the
saved session before usage requests when it is expired or within two minutes
of expiry, and retries once if the usage endpoint rejects an access token.
Renewal uses the official regional OAuth host, Kimi Code's per-credential
directory lock and heartbeat, and a private atomic credential write. It makes
no model request and preserves a concurrent owner login/logout. Transient
failures back off; a revoked session requires signing in again.
The protocol follows [Kimi Code 2.0.2's OAuth implementation](https://github.com/MoonshotAI/kimi-code/tree/9d07f634be94ebeb1deba2f55d247807cf729315/packages/oauth/src).
GLM also supports the selected Coding Plan credential
in current OpenCode's SQLite database, alongside upstream's older sources.
Sign into the appropriate official tool first. DeepSeek uses its explicit
in-app Platform login, which supports balance and API-key/model breakdowns.

For each Google provider, use its **Sign in** action in Codenotch Accounts.
Complete Google sign-in in the displayed window, then close that window.
Gemini opens its `/usage` page; NotebookLM opens Settings → Usage; Flow opens `https://flow.google.com/` and reads
Account details → Google Flow credits. English and Spanish quota labels are supported.
Each Google product has its own persistent WebKit store, so disconnecting one
does not erase another product's browser session. No Safari/Chrome cookies are
read or copied. Google can refuse embedded-browser sign-in; this condition
requires an alternative integration, and must not be displayed as zero usage.

Google integrations read the products' rendered quota panels, not a public
usage API. Their selectors and account sign-in must be verified on real pages.
Unknown, changed or ambiguous page layouts remain unavailable. Flow shows a
credit balance without inventing a monthly ceiling or reset date. Gemini and
NotebookLM retain the reset wording reported by Google rather than guessing
dates from a localized clock string.

## Freshness and privacy

The app refreshes at upstream's normal cadence (five minutes while idle).
WidgetKit controls display refresh scheduling, so the widget is not a second
by second monitor. It includes measurement age, marks readings stale after
15 minutes, and never assumes that a quota reset has occurred merely because
its countdown elapsed. Disabling a provider clears its exported reading.

The default local build provides **read-only** normalized widget snapshots on
`127.0.0.1:48531/widget-snapshot`. It binds only to loopback, provides no refresh
or credential endpoints, and sends no account names, keys or chat content.
Other local processes can read those normalized usage values while the app runs.
The widget keeps a local last-known snapshot and labels old readings as stale.

An Apple Development certificate with the App Group capability can optionally
use `group.com.r0llingclouds.codenotch` instead. Build both targets with
`CODENOTCH_USES_APP_GROUP=YES`,
`CODENOTCH_APP_ENTITLEMENTS=Sources/Widgets/App.entitlements` and
`CODENOTCH_WIDGET_ENTITLEMENTS=Widgets/Widget.entitlements` using that signing
identity. The default local build needs no Apple Developer membership.

Parser and snapshot regression tests are in `Tests/UsageWidgetTests.swift`.
Successful compilation alone does not verify WidgetKit registration or Google
sign-in. Verify gallery registration, rendered widgets, a real quota refresh,
and each Google sign-in after installing.

## Verified locally

On 2026-09-20, the Release app launched from `/Applications/Codenotch.app`;
macOS registered the extension and the owner added **All AI usage** to the
desktop and confirmed live readings. All eight providers returned real data
after account setup, including Kimi's current monthly quotas, GLM Max through
OpenCode and Flow's credit balance. The Gemini and NotebookLM quota panels and
Flow's account credit panel were inspected in the app. The app passed 1,711
local tests (three skipped), followed by 26 focused tests covering the final
provider and credential changes.

For visual checks, `Scripts/render-widgets.swift` renders the actual SwiftUI
views at desktop widget sizes from a normalized snapshot JSON. Keep generated
images and snapshots under the ignored `build/` directory; they can contain
personal usage and balances. The redesigned widgets were checked in all four
sizes/layouts and in the unconnected state. The complete suite passed again:
1,714 tests, three skipped, zero failures.

The Cursor update adds a ninth provider, a three-column overview and a Cursor
choice for individual widgets. Twenty focused Cursor parser and widget snapshot
tests passed, including separate Auto/API allowances. The full-suite rerun was
blocked by the local Xcode test host while loading/symbolicating files; it is
not counted as a successful full run. The native overview and Google layouts
were rendered and checked again, including the sub-1% Cursor reading.
Release build 21 was installed and its registered extension's cache confirmed
all nine providers, including a ready Cursor reading from the signed-in editor.

Release build 22 renewed the previously expired Kimi session automatically on
launch and fetched a fresh quota. Both the app snapshot and the registered
widget's cache reported all nine providers ready. The full suite passed 1,729
tests (three skipped, zero failures), followed by all 15 final renewal tests,
including a second expiry using the rotated refresh token. The earlier local
Xcode loader/symbolicator stall was avoided with products under `/tmp` and
`ENABLE_DEBUG_DYLIB=NO DEBUG_INFORMATION_FORMAT=dwarf-with-dsym`; no system
security settings were changed.

Build 23 removes the overview branding and readiness badge, compacts the title
and gives the cards more height. Native renders of the large overview and
Google widget were inspected; the complete suite passed 1,730 tests with three
skipped and zero failures.
