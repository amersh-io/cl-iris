# Changelog

All notable changes to cl-iris are listed here. The project follows
[Semantic Versioning](https://semver.org/); until 1.0, a minor release may
change the API.

## Unreleased

### Fixed

- With `:quit-on-last-window-closed`, a loop no longer quits before its
  `on-launch` because a window closed in an earlier loop: only a window
  closed in the running loop counts.
- A destroyed webview, or a closed window, is no longer taken for a newer
  one that Objective-C gave the same address; using it signals
  `webview-destroyed` or `window-closed`. Every webview function checks,
  `eval-js :wait nil` included, and destroying a webview twice is harmless.

### Added

- `webview-destroyed`, `webview-destroyed-p`.
- `*webview*`, bound to the calling webview while any of its handlers runs.

## 0.1.0 — 2026-11-21

The first release: native windows and webviews for SBCL on macOS (Apple
silicon), with CFFI as the only dependency.

### Objective-C runtime (`cl-iris/objc`)

- `send` with explicit CFFI signatures, structs by value (`ns-point`,
  `ns-size`, `ns-rect`), class and selector lookup by name.
- Foundation values to Lisp and back, following JSON: strings, numbers,
  booleans, `:null`, vectors and `equal` hash tables.
- Classes declared from Lisp with `define-objc-class`, whose methods can be
  redefined while instances are alive; `send-super`.
- Blocks made from Lisp functions, owned by the runtime through copy and
  dispose helpers; integer handles for Lisp values that cross into C.
- Objective-C exceptions reported with the Lisp backtrace before the
  process ends; errors in callbacks never unwind into C.
- Introspection: class names, superclasses, methods and protocols,
  `describe-objc`.

### Windows and the application (`cl-iris/window`)

- The `NSApplication` loop on the main thread (`run-application`) and
  `on-main`, which hands work to it from any thread and never leaves a
  waiter hanging when the loop stops.
- `window` objects: title, size, position, minimum and maximum size,
  style, level, opacity, background, appearance, visibility, focus,
  minimize, zoom and full screen, all through `setf` accessors.
- Window events and close requests that can be refused; application
  events, quitting, the Dock badge, theme changes.
- A menu bar with a default Edit menu (copy and paste work in webviews) and
  items that call Lisp; screens and scale factors; timers.
- `with-application`, `with-window`, `with-main-thread`, and
  `*window-defaults*`.

### Webviews (`cl-iris/webview`)

- `webview` objects in windows, one or several, with the options of wry:
  URL or HTML, headers, init scripts, user agent, devtools, transparency,
  zoom, incognito, proxies and more.
- `iris.post` and `iris.invoke` (a Promise answered by Lisp) from every
  frame; `eval-js` with results converted to Lisp and JavaScript errors as
  conditions.
- Custom URL schemes answered from Lisp, synchronously or later from any
  thread, never after WebKit has stopped the task.
- Navigation, page load, title, new window, download, permission and
  drag-and-drop handlers; `alert`, `confirm`, `prompt` and file pickers;
  cookies, browsing data, printing to the print panel or a PDF.

### Around the code

- `docs/parity.md` compares cl-iris with wry and tao row by row.
- Quint models of main-thread dispatch, URL scheme tasks and the completion
  block's lifetime in `spec/`, checked with TLC.
- Five runnable `examples/`, each run by the test suite.
- A test suite that keeps its windows invisible; CI on macOS.
