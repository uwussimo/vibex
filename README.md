# Vibex

A native macOS workspace for building while watching: **Terminal | iOS Simulator | Netflix** in one window.

- **Terminal** — real PTY terminals with tabs (SwiftTerm, Metal renderer). Run Claude Code here.
- **Simulator** — the real Simulator.app device window, docked into the middle column.
- **Browser** — a Netflix-first WebKit browser with a slim URL bar. Login persists between launches.

## Requirements

- macOS 26, Xcode 26 with at least one iOS simulator runtime
- [XcodeGen](https://github.com/yonaskolb/XcodeGen): `brew install xcodegen`

## Build and run

```sh
make run        # generates Vibex.xcodeproj, builds Debug, launches the app
make test       # unit tests (Swift Testing)
make open       # open the project in Xcode
```

The first time Xcode opens the project it asks to trust SwiftTerm's build plugin. Command-line builds pass
`-skipPackagePluginValidation` for the same reason.

## Slim simulators (simslim)

Vibex boots simulators through [simslim](https://github.com/MobAI-App/simslim) when it is installed. simslim
disables the background daemons a simulator does not need (Siri, Spotlight, iCloud sync, photo analysis…),
which cuts a simulator's memory roughly 4× and lets several run side by side. Install it with:

```sh
brew install mobai-app/tap/simslim
```

or use the leaf button in the simulator header, which runs that command in a terminal tab. The leaf shows the
selected device's state (filled = slim) and toggles it; the device picker shows the live memory footprint. Trade-offs:
Spotlight, push notifications, StoreKit and universal links stop working inside a slim simulator. Turn it off per
device with the leaf or globally with Simulator → Boot Slim.

## Signing

`project.yml` signs with a specific Apple Development certificate (by SHA-1 hash). That keeps the app's code
requirement stable, so the Accessibility grant survives rebuilds. Ad-hoc signing would invalidate it on every
build. If you change the certificate, run `tccutil reset Accessibility com.yusuf.vibex` and grant again.

## Permissions

None. Vibex talks to CoreSimulator directly, so it needs neither Accessibility nor Screen Recording.

## Using Vibex from Claude Code (MCP)

Vibex serves an MCP server on `http://127.0.0.1:5150/mcp` (next free port if 5150 is taken), guarded by a bearer
token, and registers itself with the Claude Code CLI at user scope on launch (`claude mcp get vibex` shows it).
Every Claude Code session, including the ones in Vibex's terminal (which also gets `VIBEX_MCP_URL` and
`VIBEX_MCP_TOKEN`), can then drive the workstation:

- **Simulator**: `simulator_list/boot/shutdown/info`, `simulator_screenshot`, `simulator_describe` (accessibility
  tree with refs), `simulator_find`, `simulator_tap_element`, `simulator_tap/long_press/swipe/type/press_key/button`,
  `simulator_install_app/launch_app/terminate_app/list_apps/open_url/logs`.
- **Browser**: `browser_tabs/new_tab/close_tab/select_tab/navigate/back/forward/reload`, `browser_snapshot`
  (page tree with refs), `browser_click/type/press/scroll/text/screenshot/evaluate/console/requests/wait`.
- **Workspace**: `vibex_layout`, `vibex_focus`, `vibex_notify`, `terminal_run`, `terminal_tabs`.

The title bar shows `mcp :5150` with a green dot while a client is active. Vibex → "Copy MCP Config" puts the
`claude mcp add` command and JSON on the clipboard; "Re-register MCP with Claude Code" rotates the token.
`skills/vibex/SKILL.md` teaches an agent the workflow.

## Keyboard

| Shortcut | Action |
| --- | --- |
| ⌘T / ⌘W | New / close terminal tab |
| ⌘⇧[ / ⌘⇧] | Previous / next tab |
| ⌘K | Clear terminal |
| ⌘1 / ⌘2 / ⌘3 | Focus terminal / simulator / browser |
| ⌘⇧B | Build mode: wide terminal, simulator at natural size, Netflix mini player |
| ⌘⇧W | Watch mode: Netflix wide, simulator hidden |
| ⌘⇧0 | Back to your own divider positions |
| ⌘L / ⌘R / ⌘[ / ⌘] | Browser: open location, reload, back, forward |
| ⌘⇧N | Browser: go to Netflix |
| ⌘⇧H / ⌘⇧L | Simulator: Home / Lock |
| ⌘⇧S | Copy a screenshot of the booted simulator |

## How the embedded simulator works

Vibex does what Simulator.app and idb do, minus the window: it loads Xcode's private CoreSimulator and
SimulatorKit frameworks, finds the booted device's main display, and reads its framebuffer as an IOSurface.
That surface is drawn by a CALayer (zero-copy, GPU) and refreshed on the display's per-frame callback.
Clicks and drags become Indigo touch messages; keys become Indigo keyboard messages; Home and Lock are
hardware-button messages, all sent through `SimDeviceLegacyHIDClient`. Devices boot headlessly with
`simctl` (or `simslim on`), so Simulator.app never needs to run, and several devices can be booted and
switched between from the device picker.

This relies on private API that Apple changes between Xcodes. It is verified on Xcode 26.6 / CoreSimulator
1051. idb's notes say CoreSimulator 1155.4+ drops the legacy input path in favour of a `dtuhidd` transport;
when Xcode moves there, `SimulatorInput` needs that transport.

## Layout

```
Vibex/
  App/        AppDelegate, main entry, window, menu
  Layout/     split view controller, layout modes, spring animator
  Terminal/   SwiftTerm tabs, theme, session
  Simulator/  simctl + simslim clients, header, pane; Embedded/ holds the CoreSimulator bridge,
              framebuffer, display view and HID input
  Browser/    WKWebView factory, toolbar, pane
  Support/    logging, defaults, accessibility permission, shared UI
VibexTests/   Swift Testing suites for layout math, spring, simctl parsing, URL handling
```
