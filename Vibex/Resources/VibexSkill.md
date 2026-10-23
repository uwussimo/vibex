---
name: vibex
description: How to work inside Vibex, the Mac workstation this session may be running in (terminal, embedded iOS Simulator, side browser and Git in one window), and how to use its MCP tools (simulator_*, browser_*, terminal_*, vibex_*). Use it whenever TERM_PROGRAM is Vibex or VIBEX_PROJECT is set, whenever those MCP tools are available, and whenever the task involves running, viewing, tapping or testing an iOS app or a web page.
---

<!-- Installed by Vibex {{VERSION}}. Vibex keeps this file current and replaces it when it updates. -->

# Working in Vibex

Vibex is a native Mac app: one window per project folder, laid out like VS Code. The user sees, side by
side, the terminal you run in, an embedded iOS Simulator, a tabbed WebKit browser, and the Source Control
sidebar with every diff you make. Its built-in MCP server lets you see and drive all of it.

You are inside Vibex when `TERM_PROGRAM=Vibex` or `VIBEX_PROJECT` is set. Your tool calls act on the
window of the project whose terminal you run in, never another one. With several projects open,
`vibex_projects` lists them and results start with `[project: name]`.

If none of the tools below are available, Vibex isn't running or isn't registered with Claude Code: ask the
user to open Vibex, or to choose **Vibex › Re-register MCP with Claude Code**.

## Principles

- **The user is watching.** Everything you do in the simulator and browser happens on screen. Work in
  plain sight, and say what you're about to do before long actions.
- **Prefer structure over pixels.** Use `simulator_describe` / `simulator_find` and `browser_snapshot` to
  find elements, then act by ref. Take screenshots only when layout, images or color matter.
- **Verify every action.** Taps, swipes, typing and clicks don't return what happened. Call
  `simulator_describe`, `simulator_screenshot`, `browser_snapshot` or `browser_console` afterwards.
- **Don't take over the user's tabs.** The browser may be playing video in a tab. Open your own with
  `browser_new_tab` instead of navigating an existing one.
- **Long-running processes go in a visible terminal tab.** Use `terminal_run` for dev servers and watchers
  so the user can see and stop them, rather than backgrounding them in your own shell.
- **Tell the user when something long finishes** with `vibex_notify`.

## iOS apps

1. `vibex_run` builds the project for the window's simulator, boots it if needed, installs and launches the
   app. Check progress with `vibex_run_status` (phase, exit code, the tail of the build log). Stop with
   `vibex_stop`. A `.vibex.json` in the project root overrides what Vibex detects.
2. `simulator_describe` returns the frontmost app's accessibility tree with refs like `[ref=r12]` and frames
   in points. `simulator_find` searches it by label or identifier.
3. `simulator_tap_element` taps by ref or label. Use `simulator_tap` / `simulator_swipe` / `simulator_long_press`
   with point coordinates only when there is no accessible element (`simulator_info` gives the screen size).
4. Type with `simulator_type` after tapping a field; `simulator_press_key` for return, tab and arrows;
   `simulator_button` for home and lock.
5. Read the app's logs with `simulator_logs` (filter by bundle id). Deep links: `simulator_open_url`.
6. Manage apps with `simulator_install_app`, `simulator_launch_app`, `simulator_terminate_app`,
   `simulator_list_apps`; devices with `simulator_list`, `simulator_boot`, `simulator_shutdown`.

Add accessibility labels and identifiers to views you build; they make the app testable this way.

## Web pages

1. Start the dev server with `vibex_run` (a `package.json` dev/start script opens a Preview tab once it
   answers) or with `terminal_run` and then `browser_new_tab` on its URL.
2. `browser_snapshot` returns the page as a compact tree with refs like `[ref=e12]`; refs change with each
   snapshot. Then `browser_click`, `browser_type` (set `submit` to press Enter), `browser_press`,
   `browser_scroll`.
3. Check `browser_console` for errors and `browser_requests` for failed API calls after every change.
   `browser_text` reads the visible text; `browser_wait` waits for a selector or text.
4. `browser_screenshot` for visual checks; `browser_evaluate` runs JavaScript when nothing else fits.
5. Tabs: `browser_tabs`, `browser_select_tab`, `browser_close_tab`, `browser_back`, `browser_forward`,
   `browser_reload`, `browser_navigate` (only in tabs you opened).

## The window

- `terminal_run` opens a terminal tab in the project and types a command the user can watch and stop;
  `terminal_tabs` lists them.
- `vibex_layout` switches between `build` (terminal wide, editor sized to the simulator), `watch` (browser
  wide) and `balanced`.
- `vibex_focus` brings a pane forward: `terminal`, `simulator`, `browser`, or `agents` (the AI Agents tab;
  it also returns the current Claude session's API value and when it resets).
- `vibex_notify` shows a toast in the window, and a system notification when Vibex is in the background.
- `vibex_open_project` opens another folder in its own window.

Every change you make to files shows up in the user's Source Control sidebar as a diff, so keep changes
focused and explain them; the user reviews and commits there.
