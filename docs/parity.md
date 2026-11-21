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
| `with_url_and_headers`, `with_headers` | `make-webview :headers` | done | "a webview's first request carries the headers it was given" |
| `with_html` | `make-webview :html` (and `:base-url`) | done | "a webview can start from a string of HTML" |
| `with_initialization_script` | `:init-scripts`, `add-init-script` | done | "init scripts run before the page's own scripts", "add-init-script takes effect from the next load" |
| `with_initialization_script_for_main_only` | `(source :main-frame-only t)` in `:init-scripts` | done | "a main-frame-only init script skips iframes" |
| `with_custom_protocol` | `:protocols` (or `:on-request` for one) | done | "fetch reaches the Lisp scheme handler", "one webview answers several schemes", "a request carries its method, headers and body" |
| `with_asynchronous_custom_protocol` | `:protocols` entry with `:async t`, `respond` from any thread | done | "an asynchronous handler answers later from another thread", "an answer to a stopped request is dropped, not sent" |
| `with_ipc_handler` | `:on-message` (`iris.post`), plus `:on-invoke` (`iris.invoke`, a Promise of the answer — wry has no reply) | done | "iris.post reaches on-message", "iris.invoke resolves with what on-invoke returns", "an asynchronous on-invoke answers later from another thread" |
| `with_navigation_handler` | `:on-navigate` (allow or deny) | done | "on-navigate lets a navigation through", "on-navigate can refuse a navigation" |
| `with_new_window_req_handler` | `:on-new-window` (`:here`, `:browser` or `nil`) | done | "on-new-window can refuse window.open" |
| `with_on_page_load_handler` | `:on-page-load` (started, finished, failed) | done | "on-page-load hears a page start and finish", "on-page-load hears a load fail" |
| `with_document_title_changed_handler` | `:on-title-change` | done | "on-title-change hears a script change the title" |
| `with_drag_drop_handler` | `:on-drag-drop` (`:enter`, `:over`, `:drop`, `:leave`) | done | "on-drag-drop hears files dragged over, with their position", "on-drag-drop can take a drop from the page" |
| `with_download_started_handler`, `with_download_completed_handler` | `:on-download` (`:started`, `:finished`, `:failed`) | done | "a response WebKit cannot show is downloaded where on-download says", "a link with the download attribute is downloaded under its name" |
| `with_permission_handler` | `:on-permission` (camera, microphone) | done | "on-permission decides a request for the microphone" |
| `with_user_agent` | `:user-agent`, `(setf webview-user-agent)` | done | "a custom user agent reaches navigator and requests", "the user agent can change on a live webview" |
| `with_devtools` | `:devtools`, `(setf webview-devtools-p)` (Web Inspector via `isInspectable`) | done | "devtools makes a webview inspectable" |
| `with_transparent` | `:transparent`, `(setf webview-transparent-p)` | done | "a transparent webview draws no background" |
| `with_background_color` | `:background-color` (as in wry: the window's background shows through; the color fills overscroll) | done | "a background color is set and the white background goes" |
| `with_visible` | `:visible` | done | "a webview can start hidden and keep running its page" |
| `with_focused` | `:focused` | done | "a webview made with :focused takes the focus" |
| `with_bounds` | `:bounds` (child webview inside a window) | done | "several webviews share one window, each in its bounds" |
| `with_autoplay` | `:autoplay` | done | "autoplay lets media start without a gesture" |
| `with_incognito` | `:incognito` (non-persistent data store) | done | "incognito webviews do not share storage" |
| `with_javascript_disabled` | `:javascript nil` | done | "with javascript off, the page's scripts do not run" |
| `with_back_forward_navigation_gestures` | `:navigation-gestures`, `(setf webview-navigation-gestures-p)` | done | "navigation gestures can be switched on and off" |
| `with_accept_first_mouse` | `:accept-first-mouse`, `(setf webview-accepts-first-mouse-p)` | done | "accept-first-mouse lets the first click through" |
| `with_background_throttling` | `:background-throttling` (macOS 14+) | done | "background throttling can be turned off" |
| `with_proxy_config` | `:proxy` (macOS 14+) | done | "a webview's requests really go through its proxy", "a SOCKS5 proxy is set on the webview's store" |
| `with_hotkeys_zoom` | — | out of scope | unsupported by wry on macOS |
| `with_clipboard` | the Edit menu (below) | out of scope | always on in WebKit on macOS; needs only the menu |
| `with_general_autofill_enabled` | — | out of scope | Windows only |

## Webview methods (wry `WebView`)

| wry method | cl-iris | Status | Test / reason |
|---|---|---|---|
| `evaluate_script` | `eval-js :wait nil` | done | "a message from JavaScript is answered by eval-js" |
| `evaluate_script_with_callback` | `eval-js` (waits) or `:callback` | done | "eval-js returns strings", "eval-js signals JavaScript errors" |
| `load_url` | `load-url` | done | "a page served from Lisp posts a message back" |
| `load_url_with_headers` | `load-url :headers` | done | "load-url sends extra headers" |
| `load_html` | `load-html` | done | "an answer to a stopped request is dropped, not sent" |
| `url` | `webview-url` | done | "webview-url tells where a webview is" |
| `reload`, `go_back`, `go_forward` | `reload`, `go-back`, `go-forward` | done | "going back and forward moves through history", "reload loads the page again" |
| `can_go_back`, `can_go_forward` | `can-go-back-p`, `can-go-forward-p` | done | "a fresh webview cannot go back or forward" |
| `zoom` | `:zoom`, `(setf webview-zoom)` | done | "zoom scales the page's CSS pixels" |
| `set_background_color` | `(setf webview-background-color)` | done | "the background color can change on a live webview" |
| `bounds`, `set_bounds` | `webview-bounds`, `(setf webview-bounds)` | done | "a webview can be moved and resized" |
| `set_visible` | `(setf webview-visible-p)` | done | "a hidden webview can be shown" |
| `focus` | `focus-webview`, `webview-focused-p` | done | "focus moves between webviews" |
| `focus_parent` | `focus-parent` | done | "focus-parent hands the focus back to the window" |
| `print` | `print-webview` (the print panel, or `:pdf` to a file) | done | "print-webview writes the page to a PDF file" |
| `cookies`, `cookies_for_url`, `set_cookie`, `delete_cookie` | `cookies` (`:url`), `set-cookie`, `delete-cookie` | done | "set-cookie stores a cookie that cookies lists", "cookies for a URL are those it would be sent", "delete-cookie removes a cookie" |
| `clear_all_browsing_data` | `clear-browsing-data` | done | "clear-browsing-data removes cookies and stored data" |
| `open_devtools`, `close_devtools`, `is_devtools_open` | — | out of scope | needs private WebKit API; `:devtools` enables the inspector from the context menu |
| `id` | — | out of scope | see `with_id` |

## Window and event loop (tao, the parts a webview app needs)

| tao feature | cl-iris | Status | Test / reason |
|---|---|---|---|
| event loop on the main thread | `run-application` | done | every application test |
| `EventLoopProxy` (send work to the loop) | `on-main` | done | "on-main returns every value" |
| exit the loop | `stop-application` | done | every application test |
| create a window | `make-window` | done | "a window gets a window number" |
| title | `window-title`, `(setf window-title)` | done | "a window's title can be changed" |
| inner size | `window-content-size`, `resize-window` | done | "a window can be resized" |
| outer size and position | `window-frame`, `window-position`, `move-window` | done | "a window can be moved", "the frame includes the title bar" |
| center | `center-window`, `make-window :center` | done | "centering moves a window into the middle of its screen" |
| min and max size | `set-window-min-size`, `set-window-max-size`, `:min-size`, `:max-size` | done | "a window keeps the minimum and maximum sizes it is given" |
| resizable, decorations | `:style`, `window-resizable-p`, `window-decorated-p` | done | "a window can be made fixed in size", "a window without decorations has no title bar" |
| always on top | `(setf window-level)` `:floating` | done | "a window can be kept on top" |
| minimize, maximize | `minimize-window`, `restore-window`, `(setf window-maximized-p)` | done | "a window can be minimized and restored", "a window can be maximized and brought back" |
| fullscreen | `(setf window-fullscreen-p)` | done | "a new window is not in full screen"; entering it is not exercised, since it takes over a Space |
| visible, focus | `show-window`, `hide-window`, `focus-window` | done | "a hidden window is not visible", "focusing a window brings it in front of the application's others" |
| transparent window, background color | `window-transparent-p`, `window-background-color`, `window-alpha` | done | "a window can be made transparent", "a window's background color can be set and read back" |
| theme (light/dark) | `(setf window-appearance)`, `system-appearance`, `theme-change-handler` | done | "a window can be drawn dark or light", "a change of the system's appearance is reported" |
| title bar options | `window-title-visible-p`, `window-titlebar-transparent-p`, `:full-size-content-view` | done | "the title bar can be made transparent over full-size content" |
| shadow, click-through | `window-shadow-p`, `window-ignores-mouse-p` | done | "a window's shadow can be turned off and on", "a window can let mouse events pass through" |
| content protection | `window-content-protected-p` | done | "a window's content can be kept out of screen captures" |
| visible on all workspaces | `window-on-all-spaces-p` | done | "a window can be shown on every Space" |
| window builder | `make-window` keywords | done | "make-window applies every option it is given" |
| window events: close requested, resized, moved, focused, minimized, closed | `window-event-handler`, `window-close-request-handler` | done | "resizing a window reports :resized with the new size", "a close request the handler refuses leaves the window open" |
| using a closed window | `window-closed` condition | done | "a released window is refused instead of crashing the process" |
| quit requests (Cmd+Q, Dock) | `run-application :on-quit-request`, `quit-application` | done | "a refused quit request keeps the loop running", "an accepted quit request stops the loop" |
| reopen, last window closed | `:on-reopen`, `:quit-on-last-window-closed` | done | "reopening calls the handler with whether a window is visible" |
| application menu | `set-menu-bar`, `default-menu-bar` | done | "choosing a menu item calls its Lisp action", "the default menu bar has an Edit menu for copy and paste" |
| monitors, scale factor | `screens`, `window-screen`, `window-scale-factor` | done | "there is at least one screen, described in full", "a window knows its screen and scale factor" |
| timers | `run-after`, `run-every`, `cancel-timer` | done | "run-after calls its function once on the main thread, later", "run-every fires repeatedly until cancelled" |
| Dock badge, user attention | `dock-badge`, `request-user-attention` | done | "the Dock icon can carry a badge" |
| hide the application | `hide-application`, `unhide-application` | done | "hiding the application hides its windows" |
| cursor, raw keyboard and mouse events | — | out of scope | input belongs to the webview |
| window and dock icons | — | out of scope | set by the `.app` bundle |

## macOS basics outside both lists

| Need | cl-iris | Status | Test / reason |
|---|---|---|---|
| Cmd+C / Cmd+V / Cmd+A / undo in the webview | a default Edit menu | done | "the default menu bar has an Edit menu for copy and paste" |
| `alert`, `confirm`, `prompt` | `:on-dialog`, else sheets on the window | done | "on-dialog answers confirm()", "without on-dialog, confirm() shows a sheet and hears its answer" |
| links with `target=_blank` | routed to `:on-new-window`, else opened in place | done | "a target=_blank link opens in place by default" |
| `<input type=file>` | `:on-file-dialog`, else an open panel sheet | done | "on-file-dialog chooses the files for an input" |
| web content process crash | `:on-web-process-terminated`, else reload | done | "on-web-process-terminated hears the content process die", "without a handler, a webview whose process died reloads", "an eval-js pending when the process dies ends with an error" |
| Objective-C exceptions | reported before the process aborts | done | "an uncaught exception is reported with its name and reason" |
| tests that never steal focus | `:activation-policy :accessory`, `:activate nil` | done | every application test |
