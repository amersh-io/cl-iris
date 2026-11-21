# Parity with wry and tao

cl-iris covers the same ground as [wry](https://github.com/tauri-apps/wry)
(the webview) and the part of [tao](https://github.com/tauri-apps/tao) (the
window and event loop) that a webview application needs, on macOS. This page
lists every wry option and method, the tao features in scope, and the macOS
basics neither list names but every webview app needs. It is the definition
of done for the project: each row is either covered by a named test, still
planned, or out of scope with a reason.

Status: **done** (with the test that covers it), **planned**, or
**out of scope**.

## Webview options (wry `WebViewBuilder::with_*`)

| wry option | cl-iris | Status | Test / reason |
|---|---|---|---|
| `with_id` | the webview object is its own identity | out of scope | Lisp code holds the object itself |
| `with_url` | `make-webview :url` | done | "a page served from Lisp posts a message back" |
| `with_url_and_headers`, `with_headers` | `make-webview :headers` | planned | |
| `with_html` | `make-webview :html` | planned | `load-html` exists |
| `with_initialization_script` | `:init-scripts` | planned | |
| `with_initialization_script_for_main_only` | `:init-scripts` with a main-frame flag | planned | |
| `with_custom_protocol` | `:on-request` | done | "fetch reaches the Lisp scheme handler" |
| `with_asynchronous_custom_protocol` | responder callable from any thread | planned | |
| `with_ipc_handler` | `:on-message` | done | "a message from JavaScript is answered by eval-js" |
| `with_navigation_handler` | `:on-navigate` (allow or deny) | planned | |
| `with_new_window_req_handler` | `:on-new-window` | planned | |
| `with_on_page_load_handler` | `:on-page-load` (started, finished) | planned | |
| `with_document_title_changed_handler` | `:on-title-change` | planned | |
| `with_drag_drop_handler` | `:on-drag-drop` | planned | |
| `with_download_started_handler`, `with_download_completed_handler` | `:on-download` | planned | |
| `with_permission_handler` | `:on-permission` (camera, microphone) | planned | |
| `with_user_agent` | `:user-agent` | planned | |
| `with_devtools` | `:devtools` (Web Inspector via `isInspectable`) | planned | |
| `with_transparent` | `:transparent` | planned | |
| `with_background_color` | `:background-color` | planned | |
| `with_visible` | `:visible` | planned | |
| `with_focused` | `:focused` | planned | |
| `with_bounds` | `:bounds` (child webview inside a window) | planned | |
| `with_autoplay` | `:autoplay` | planned | |
| `with_incognito` | `:incognito` (non-persistent data store) | planned | |
| `with_javascript_disabled` | `:javascript nil` | planned | |
| `with_back_forward_navigation_gestures` | `:navigation-gestures` | planned | |
| `with_accept_first_mouse` | `:accept-first-mouse` | planned | |
| `with_background_throttling` | `:background-throttling` (macOS 14+) | planned | |
| `with_proxy_config` | `:proxy` (macOS 14+) | planned | |
| `with_hotkeys_zoom` | — | out of scope | unsupported by wry on macOS |
| `with_clipboard` | the Edit menu (below) | out of scope | always on in WebKit on macOS; needs only the menu |
| `with_general_autofill_enabled` | — | out of scope | Windows only |

## Webview methods (wry `WebView`)

| wry method | cl-iris | Status | Test / reason |
|---|---|---|---|
| `evaluate_script` | `eval-js :wait nil` | done | "a message from JavaScript is answered by eval-js" |
| `evaluate_script_with_callback` | `eval-js` (waits) or `:callback` | done | "eval-js returns strings", "eval-js signals JavaScript errors" |
| `load_url` | `load-url` | done | "a page served from Lisp posts a message back" |
| `load_url_with_headers` | `load-url :headers` | planned | |
| `load_html` | `load-html` | planned | test still to come |
| `url` | `webview-url` | planned | |
| `reload`, `go_back`, `go_forward` | `reload`, `go-back`, `go-forward` | planned | |
| `can_go_back`, `can_go_forward` | `can-go-back-p`, `can-go-forward-p` | planned | |
| `zoom` | `(setf webview-zoom)` | planned | |
| `set_background_color` | `(setf webview-background-color)` | planned | |
| `bounds`, `set_bounds` | `webview-bounds`, `(setf webview-bounds)` | planned | |
| `set_visible` | `(setf webview-visible-p)` | planned | |
| `focus`, `focus_parent` | `focus-webview`, `focus-window` | planned | |
| `print` | `print-webview` | planned | |
| `cookies`, `cookies_for_url`, `set_cookie`, `delete_cookie` | `cookies`, `set-cookie`, `delete-cookie` | planned | |
| `clear_all_browsing_data` | `clear-browsing-data` | planned | |
| `open_devtools`, `close_devtools`, `is_devtools_open` | — | out of scope | needs private WebKit API; `:devtools` enables the inspector from the context menu |
| `id` | — | out of scope | see `with_id` |

## Window and event loop (tao, the parts a webview app needs)

| tao feature | cl-iris | Status | Test / reason |
|---|---|---|---|
| event loop on the main thread | `run-application` | done | every application test |
| `EventLoopProxy` (send work to the loop) | `on-main` | done | "on-main returns every value" |
| exit the loop | `stop-application` | done | every application test |
| create a window | `make-window` | done | "a window gets a window number" |
| title | `window-title`, `(setf window-title)` | planned | getter done: "a window keeps its title" |
| inner size | `window-content-size`, setter | planned | getter done: "a window has the content size asked for" |
| min and max size | `:min-size`, `:max-size` | planned | |
| position, center | `window-position`, `center-window` | planned | |
| resizable, decorations | `:resizable`, `:style` | planned | |
| always on top | `:level` | planned | |
| minimize, maximize, fullscreen | `minimize-window`, `zoom-window`, `(setf window-fullscreen-p)` | planned | |
| visible, focus | `show-window`, `hide-window`, `focus-window` | planned | |
| transparent window, background color | `:transparent`, `:background-color` | planned | |
| theme (light/dark) | `(setf window-appearance)` | planned | |
| window events: close requested, resized, moved, focused, destroyed | `:on-close-request` and friends | planned | |
| application menu | `set-menu-bar` | planned | |
| monitors, scale factor | `screens`, `window-scale-factor` | planned | |
| timers | `on-main :after` | planned | |
| cursor, raw keyboard and mouse events | — | out of scope | input belongs to the webview |
| window and dock icons | — | out of scope | set by the `.app` bundle |

## macOS basics outside both lists

| Need | cl-iris | Status | Test / reason |
|---|---|---|---|
| Cmd+C / Cmd+V / Cmd+A / undo in the webview | a default Edit menu | planned | |
| `alert`, `confirm`, `prompt` | WKUIDelegate panels | planned | |
| links with `target=_blank` | routed to `:on-new-window` or opened in place | planned | |
| `<input type=file>` | open panel | planned | |
| web content process crash | `:on-web-process-terminated`, reload | planned | |
| Objective-C exceptions | reported before the process aborts | done | "an uncaught exception is reported with its name and reason" |
| tests that never steal focus | `:activation-policy :accessory`, `:activate nil` | done | every application test |
