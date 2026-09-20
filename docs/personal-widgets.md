# Personal usage widgets

This fork adds native WidgetKit widgets to Codenotch. The background app reads
provider usage; the widget extension only receives normalized quota windows,
balances, status and measurement dates. Upstream Codenotch remains MIT licensed.

## Widgets

- **All AI usage** (large): Codex, Claude, Kimi, GLM, DeepSeek, Gemini chat,
  NotebookLM and Google Flow.
- **Provider usage** (small or medium): choose one provider in Edit Widget.
- **Google AI Pro** (medium): three separate meters for Gemini chat, NotebookLM
  and Flow. Antigravity and Gemini API quotas do not represent these products.

The floating notch is hidden by default in this fork. Codenotch remains in the
menu bar for sign-in, refresh and settings. Close settings to leave collection
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

Codex and Claude use upstream's local credential discovery. The OpenAI meter
measures **Codex usage on your ChatGPT plan**, not ChatGPT web chat activity.
Kimi reads the managed Kimi Code login, including the current global `.ai`
region and environment-specific credential file. Its current 5h and monthly
ratios take priority over legacy counters. Kimi itself owns token renewal;
opening Kimi Code and running `/usage` refreshes an expired session without
making a model request. GLM also supports the selected Coding Plan credential
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
