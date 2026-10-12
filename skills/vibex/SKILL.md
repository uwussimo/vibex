---
name: vibex
description: Drive the Vibex workstation from Claude Code — the embedded iOS Simulator (screenshots, accessibility tree, taps, typing, app install/launch, logs) and the side browser (tabs, page snapshots with refs, clicks, console and network logs) through the `vibex` MCP server. Use when working inside Vibex on an iOS app or a web app you want to see running.
---

# Vibex

You are running inside Vibex: a terminal, an embedded iOS Simulator and a side browser in one window the user is watching. The `vibex` MCP server (tools `mcp__vibex__*`) is your hands.

## Loop for iOS work

1. `simulator_info` once to learn the screen size in points.
2. Build with `xcodebuild … -sdk iphonesimulator`, then `simulator_install_app {path}` and `simulator_launch_app {bundleId}`.
3. `simulator_describe` to read the UI (roles, labels, refs, frames). Act with `simulator_tap_element {ref}` or `{label}`; fall back to `simulator_tap {x,y}` in points for unlabelled views.
4. `simulator_type` for text (tap the field first), `simulator_swipe` to scroll, `simulator_button home` to leave an app.
5. `simulator_screenshot` when layout or visuals matter; it is a JPEG, so use it to look, not to measure. `simulator_logs {bundleId}` for crashes and prints.

## Loop for web work

1. `browser_new_tab {url}` — never navigate the user's existing tab, Netflix may be playing there.
2. `browser_snapshot` → refs like `e12` → `browser_click`, `browser_type {submit}`, `browser_press`, `browser_scroll`.
3. `browser_console` and `browser_requests {failedOnly}` after reproducing a bug. `browser_evaluate` for anything else.
4. Close your tab with `browser_close_tab` when done.

## Projects and Run

Vibex has one window per project folder. Calls from Claude Code in a project's terminal act on that project's window; results start with `[project: name]` when several are open. `vibex_projects` lists them, `vibex_open_project {path}` opens one.

`vibex_run` runs the project like the user's Run button: iOS apps build for this window's simulator and launch, web projects start their dev server and open a Preview tab. Poll `vibex_run_status` for the phase, exit code and output tail; `vibex_stop` stops it. A `.vibex.json` in the project root overrides detection.

## Workspace

`terminal_run` starts dev servers in a tab the user can see and stop. `vibex_layout watch|build|balanced` and `vibex_focus` change what is on screen. `vibex_notify` when a long task finishes.

## Habits

- Act, then look: taps and clicks do not return screenshots.
- Prefer refs and labels over coordinates.
- Keep screenshots small (`maxWidth`), they cost tokens.
