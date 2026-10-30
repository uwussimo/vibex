---
name: vibex
description: How to work inside Vibex, the Mac workstation this session may be running in (Claude chat or terminal, embedded iOS Simulator, side browser and Git in one window), and how to use its MCP tools (simulator_*, browser_*, terminal_*, vibex_*) to build, run, test and verify fast. Use it whenever TERM_PROGRAM is Vibex or VIBEX_PROJECT is set, whenever those MCP tools are available, and whenever the task involves running, viewing, tapping or testing an iOS app or a web page.
---

<!-- Installed by Vibex {{VERSION}}. Vibex keeps this file current and replaces it when it updates. -->

# Working in Vibex

Vibex is one native Mac window per project: you on the left (a Claude chat or a terminal), and on the
right a live iOS Simulator and a browser, with every diff you make in Source Control. Its MCP server lets
you run the app and see it yourself. **You don't have to ask the user to check anything, and you don't
have to guess whether it works: run it and look.**

You are inside Vibex when `TERM_PROGRAM=Vibex` or `VIBEX_PROJECT` is set. Calls act on your project's
window. If the tools are missing, Vibex isn't running or registered: ask the user to open it, or to choose
**Vibex › Re-register MCP with Claude Code**. If your client defers tools, load the ones a task needs in one
batch rather than one at a time.

## The loop

Every UI change goes round this loop, and you don't call it done until the last step passes:

1. **Change** the code.
2. **Run**: `vibex_run`, then poll `vibex_run_status` until it's running or failed.
3. **Reach** the screen: `simulator_find` or `browser_snapshot`, then tap or click by ref.
4. **Look**: read the tree for behavior; take a screenshot only for layout, images and color.
5. **Check the logs**: `simulator_logs` or `browser_console` plus `browser_requests {failedOnly: true}`.
   A screen that looks right can still be throwing errors.
6. **Finish**: say what you verified and how. Say plainly what you could not verify.

When a build fails, `vibex_run_status` has the tail of the log: fix the first error, not the last.

## Choosing the fast tool

Wrong tool choice is the main cost here. A screenshot costs far more tokens and tells you less than a tree.

| You want to | Use | Not |
|---|---|---|
| Build, install and launch | `vibex_run` | `xcodebuild` by hand, then install and launch |
| Start a web project | `vibex_run` | backgrounding `npm run dev` in your shell |
| Find one element | `simulator_find {label}` | `simulator_describe`, then reading it all |
| Tap something labelled | `simulator_tap_element {label}` | a screenshot, then guessing coordinates |
| Know what's on screen | `simulator_describe`, `browser_snapshot` | a screenshot |
| Read a web page | `browser_text` | `browser_screenshot` |
| Wait for a page | `browser_wait {text}` or `{selector}` | a fixed `{ms}` sleep |
| See layout or color | a screenshot with `maxWidth` around 400 | the default size, repeatedly |
| Compare screen sizes | `simulator_screenshot_all` | switching devices and taking several |
| Show a visual change | `simulator_snapshot` "before" and "after" | describing it in words |

Make calls in parallel when they don't depend on each other, such as logs alongside a tree. A tap and the
look that follows it do depend on each other: tap, then look. Taps, typing and clicks don't return what
happened.

## iOS apps

- `vibex_run` builds for this window's simulator, boots it if needed, installs and launches. `vibex_stop`
  stops it. A `.vibex.json` in the project root overrides what Vibex detects:
  `{"run": {"kind": "ios", "scheme": "MyApp"}}`.
- Refs like `[ref=r12]` come from `simulator_describe` and `simulator_find`, with frames in points.
- `simulator_tap_element` takes a ref or a label. Use `simulator_tap`, `simulator_swipe` and
  `simulator_long_press` with points only when nothing is accessible; `simulator_info` has the screen size.
- `simulator_type` types into the focused field, so tap it first. It uses a US keyboard layout; `\n` is
  Return. `simulator_press_key` for return, tab and arrows. `simulator_button` for home and lock.
- `simulator_logs {bundleId, seconds}` after a crash or odd behavior. `simulator_open_url` for deep links,
  which get you to a deep screen much faster than tapping there.
- **Add accessibility identifiers to the views you build.** It's what makes the next check one call.
- `simulator_list`, `simulator_boot`, `simulator_shutdown`, `simulator_list_apps`, `simulator_install_app`,
  `simulator_launch_app`, `simulator_terminate_app` for the rest.

## Web pages

- `vibex_run` starts a `package.json` dev or start script and opens a Preview tab once it answers. Or use
  `terminal_run` for the server, then `browser_new_tab` on its URL.
- **Never navigate a tab you didn't open**; the user may be watching something in it. Use `browser_new_tab`,
  and `browser_close_tab` when you're done.
- `browser_snapshot` gives refs like `[ref=e12]`, then `browser_click`, `browser_type {submit: true}`,
  `browser_press`, `browser_scroll`. Refs change with each snapshot, so take a new one after the page changes.
- Pass `clear: true` to `browser_console` and `browser_requests` before reproducing a bug, so that what you
  read next comes from your reproduction.
- `browser_evaluate` runs JavaScript when nothing else fits. Prefer refs for anything the user would do.

## Designing before building

The Design tab (⌘4) draws JSON from `vibex-design/` in the project on a canvas, so the user can see and
change a product before it's built. To start one from any session, call `design_open`: it opens the tab and
returns the format. Write `design.json` and one file per screen, then check them with `design_screenshot`,
which shows how they really render and lists problems. When asked to build a design, read those files and
compare the running app with `design_screenshot`.

## The window

- `terminal_run` opens a terminal tab with a command the user can see and stop. Dev servers and watchers go
  here, not in your own background shell. `terminal_tabs` lists them.
- `vibex_layout`: `build` (you wide, editor sized to the simulator), `watch` (browser wide), `balanced`.
- `vibex_focus` brings forward `terminal`, `simulator`, `browser` or `agents` (AI Usage, which also returns
  this Claude session's API value and when it resets).
- `vibex_notify` when something long finishes: a toast, or a system notification when Vibex is in the
  background. `vibex_projects` and `vibex_open_project` for other project windows.

## Working with the user

The user is watching the simulator and browser, so work in plain sight and say what you're about to do
before long actions. Your file changes appear in Source Control as diffs, so keep them focused; the user
reviews and commits there.
