# cl-iris

Native windows and webviews for Common Lisp, macOS first.

cl-iris gives a running SBCL process AppKit windows with `WKWebView`s in
them and a two-way bridge between JavaScript and Lisp, using nothing but
[CFFI](https://cffi.common-lisp.dev/). It covers what
[wry](https://github.com/tauri-apps/wry) and the webview-facing part of
[tao](https://github.com/tauri-apps/tao) do on macOS — see
[docs/parity.md](docs/parity.md), row by row, each row with the test that
checks it.

Everything stays live: handlers given as symbols follow their redefinition,
methods of Objective-C classes declared in Lisp can be redefined while the
window is open, and an image with cl-iris loaded can be saved with
`save-lisp-and-die` and started again. The test suite checks all three.

> **Status:** early (0.0.1). The API may still change.

## Getting started

```sh
scripts/bootstrap          # installs SBCL 2.6.9 and qlot under .local/, fetches CFFI
export PATH="$PWD/.local/bin:$PATH"
qlot exec sbcl --load examples/hello.lisp
```

```lisp
(asdf:load-system "cl-iris")

(defpackage #:my-app
  (:use #:cl)
  (:local-nicknames (#:iris #:cl-iris)))
(in-package #:my-app)

;; On the main thread: run the application, and the body on another thread.
(iris:with-application ()
  (iris:with-window (window :title "Hello" :width 480 :height 320)
    (iris:with-webview (view window :html "<title>Hi</title><h1>Hello from Lisp</h1>")
      (sleep 1)
      (iris:eval-js view "document.title"))))
;; => "Hi"
```

More complete programs are in [examples/](examples/): IPC both ways, a site
served by Lisp, menus, several windows.

## Packages and systems

| System / package | What it is |
|---|---|
| `cl-iris` | The package to use: every external symbol of the window and webview layers. |
| `cl-iris/window` | The `NSApplication` loop on the main thread, windows, menus, screens, timers. |
| `cl-iris/webview` | `WKWebView`: pages, JavaScript ⇄ Lisp, custom URL schemes, navigation, panels, cookies, printing. |
| `cl-iris/objc` | The layer below: the Objective-C runtime through CFFI — `send`, classes and blocks defined in Lisp, Foundation ⇄ Lisp values, introspection. |

Each system is also a package of the same name. Use `cl-iris` with a
package-local nickname rather than `:use`, and `cl-iris/objc` when you need
to go below the API.

The only dependency is CFFI, including `cffi-libffi`, which ships with CFFI
and is needed to pass structs such as `NSRect` by value; building it needs a
C compiler (the Xcode command line tools).

## The main thread

AppKit runs only on the main thread, and the main thread spends its life in
the application loop: `run-application` (or `with-application`, which also
runs a body on another thread and stops the loop when it is done). Every
function of the window and webview layers can be called from any thread —
it hands its work to the main thread with `on-main` and waits for the
answer:

```lisp
(iris:on-main (lambda () (iris:main-thread-p)))   ; => T, from any thread
(iris:with-main-thread () (iris:main-thread-p))   ; the same, as a macro
```

A condition signalled on the main thread is signalled again in the caller.
A waiting caller is never left hanging: it gets `application-not-running`
before the loop runs, `application-stopped` when the loop ends first, and
`main-thread-timeout` after `:timeout` seconds. `on-main :wait nil` queues
work without waiting; `run-after` and `run-every` are timers on the main
thread.

## Windows

`make-window` returns a `window`, which prints its title and window number.
Every attribute is read by a function and changed with `setf`; sizes are
lists `(width height)`, positions `(x y)`, frames `(x y width height)`, in
points from the bottom-left of the main screen:

```lisp
(let ((w (iris:make-window :title "Tools" :width 400 :height 300 :center t
                           :min-size '(200 150) :level :floating)))
  (setf (iris:window-title w) "Tools (2)"
        (iris:window-size w) '(500 360)
        (iris:window-appearance w) :dark)
  (iris:window-size w))
;; => (500.0d0 360.0d0)
```

Events arrive on the main thread through `:on-event` (resized, moved,
focused, minimized, full screen, closed …) and `:on-close-request`, which
can refuse to close. `*window-defaults*` holds options for every
`make-window` call that leaves them out — the test suite uses it to keep
its windows transparent.

The application gets the standard Mac menu bar by default; its Edit menu is
what makes Cmd+C, Cmd+V and undo work in a webview. `set-menu-bar` takes a
menu bar as a list, with items that call Lisp functions:

```lisp
(iris:set-menu-bar
 (append (iris:default-menu-bar)
         `((:menu "Lisp"
            (:item "Say Hello" :key "1" :action ,(lambda () (print "hello")))))))
```

`run-application` also takes what to do on a quit request (Cmd+Q, the
Dock), on a Dock click, and whether closing the last window quits.
`screens`, `window-screen` and `window-scale-factor` describe the displays;
`dock-badge` and `request-user-attention` reach the Dock.

## Webviews

```lisp
(iris:make-webview window
  ;; Pages served by Lisp: (scheme handler &key async)
  :protocols `(("app" ,(lambda (request)
                         (values "<title>App</title><script>
                                    iris.invoke({op: 'add', args: [2, 40]})
                                      .then(sum => iris.post({sum}));
                                  </script>"
                                 "text/html"))))
  ;; iris.invoke(value) returns a Promise of this function's answer.
  :on-invoke (lambda (request)
               (reduce #'+ (gethash "args" request)))
  ;; iris.post(value) calls this.
  :on-message (lambda (message) (print (gethash "sum" message)))
  :url "app://site/index.html")
```

- **Pages talk to Lisp** through `window.iris`, defined in every frame:
  `iris.post(value)` calls `:on-message`; `iris.invoke(value)` returns a
  Promise that `:on-invoke` answers (or, with `:invoke-async`, answers later
  from any thread). Values convert like JSON: strings, numbers, `t`/`nil`
  for booleans, `:null`, vectors and `equal` hash tables.
- **Lisp talks to pages** with `eval-js`, which waits for the value (with an
  optional `:timeout`) and turns a JavaScript exception into a
  `javascript-error`. On the main thread, which has to run the script, pass
  `:wait nil` and a `:callback` instead.
- **Custom URL schemes** answer every request — `fetch()` too — with the
  request's URL, method, headers and body. A handler returns the body
  (a string or octets), a content type, a status and headers; `nil` is 404.
  An `:async` handler gets a responder and calls `respond` later, from any
  thread; if WebKit has cancelled the request meanwhile, the answer is
  dropped instead of crashing the process. WebKit does not turn a custom
  scheme's response into a download.
- **Navigation and WebKit's requests:** `:on-navigate` decides whether to
  follow a link, `:on-new-window` handles `target=_blank` and
  `window.open`, `:on-page-load` and `:on-title-change` report progress,
  `:on-dialog` answers `alert`, `confirm` and `prompt` (sheets by default),
  `:on-file-dialog` answers `<input type=file>` (an open panel by default),
  `:on-permission` answers camera and microphone requests, `:on-download`
  places downloads, `:on-drag-drop` hears files dragged over the page, and
  `:on-web-process-terminated` hears the content process die (it reloads by
  default).
- **Placement:** a webview fills its window, or sits at `:bounds` beside
  others; `webview-bounds`, `webview-visible-p` and the focus functions
  move it around.
- **Options:** `:init-scripts`, `:user-agent`, `:devtools` (the Web
  Inspector), `:transparent`, `:background-color`, `:zoom`, `:autoplay`,
  `:incognito`, `:javascript`, `:navigation-gestures`,
  `:accept-first-mouse`, `:background-throttling` and `:proxy`. As in wry,
  `:background-color` stops the webview painting its own white, so the
  window's background shows where the page paints nothing.
- **Pages and data:** `load-url` (with headers), `load-html`, `reload`,
  `go-back`, `go-forward`, `webview-url`; `cookies`, `set-cookie`,
  `delete-cookie`, `clear-browsing-data`; `print-webview`, to the print
  panel or straight to a PDF file with `:pdf`.

A handler given as a symbol, `:on-message 'my-handler`, follows
redefinitions of `my-handler`. Handlers run on the main thread; an error in
one goes to `report-error` rather than into WebKit.

## Going below the API

A `window` or `webview` is an `objc-object` standing for its `NSWindow` or
`WKWebView`. `send` accepts it in place of the pointer, so anything AppKit
or WebKit offers is one message away; `window-pointer`, `webview-pointer`,
`find-window` and `find-webview` convert both ways. `send` does not move to
the main thread by itself — AppKit traps when it is used from another one —
so wrap it in `with-main-thread`:

```lisp
(iris:with-main-thread ()
  (cl-iris/objc:send window "setHasShadow:" :bool nil :void))
```

`send` takes CFFI type/value pairs like `cffi:foreign-funcall`, optionally
followed by the return type (default `:pointer`). Classes can be declared
with methods written in Lisp, and evaluating the form again replaces the
methods of the live class:

```lisp
(in-package #:cl-iris/objc)

(define-objc-class "Adder" (:superclass "NSObject")
  (:method "add:to:" :long-long (self (a :long-long) (b :long-long))
    (+ a b)))

(send (send (send (find-class* "Adder") "alloc") "init")
      "add:to:" :long-long 2 :long-long 40 :long-long)
;; => 42
```

Blocks are made from Lisp functions and reference-counted by the runtime:

```lisp
(define-block-invoker each-object :void
  ((object :pointer) (index :unsigned-long) (stop :pointer)))

(with-block (block (cffi:callback each-object)
                   (lambda (object index stop)
                     (declare (ignore stop))
                     (format t "~D: ~A~%" index (lisp-string object))))
  (send (lisp->objc #("a" "b")) "enumerateObjectsUsingBlock:" :pointer block :void))
```

From the REPL, `describe` a window or webview to see its state, handlers
and class chain; `objc-class-methods`, `objc-class-protocols`,
`objc-superclasses` and `describe-objc` look into any Objective-C object or
class.

## Notes

- Work for the main thread, and everything a C callback refers to, is
  identified by an integer handle rather than a Lisp object's address: the
  garbage collector may move Lisp objects.
- SBCL's floating point traps are masked around everything that runs on the
  main thread (`with-cocoa-float-traps`); Cocoa does not expect them.
- Classes and selectors are looked up by name rather than cached as
  pointers, foreign caches are emptied when an image starts, and classes
  declared with `define-objc-class` are declared again, so a saved image
  carries no stale addresses.
- CFFI cannot catch an Objective-C exception, so one that reaches Lisp ends
  the process. cl-iris checks in Lisp what would raise one (a request
  WebKit has cancelled, a window already released, a URL scheme WebKit
  owns), and `run-application` installs a reporter that prints the
  exception and the Lisp backtrace before the process ends.
- The concurrency protocols — waiting on the main thread, answering URL
  scheme requests, the completion block's lifetime — have
  [Quint](https://quint-lang.org/) models in [spec/](spec/), checked with
  TLC.

## Tests

```sh
scripts/test                               # the whole suite
CL_IRIS_TEST_ONLY=eval-js scripts/test     # only checks whose names contain "eval-js"
CL_IRIS_TEST_VISIBLE=1 scripts/test        # show the test windows
scripts/check-spec                         # the Quint models' tests
```

Test windows are transparent and never take focus, so the suite can run
while you work. CI runs both suites on every push.

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute cl-iris
or work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
