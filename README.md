# cl-iris

Native windows and webviews for Common Lisp, macOS first.

cl-iris aims to give a running SBCL process an AppKit window with a
`WKWebView` inside it, and a two-way bridge between JavaScript and Lisp,
using nothing but [CFFI](https://cffi.common-lisp.dev/). Methods of
Objective-C classes declared in Lisp and the handlers of a webview can be
redefined from the REPL while the window is open, and an image with cl-iris
loaded can be saved with `save-lisp-and-die` and started again; the test
suite checks both.

> **Status:** early, but the three layers work end to end: a page served
> from Lisp can message Lisp, and Lisp can answer it with JavaScript.

## Layers

cl-iris is one repository with several ASDF systems, each built on the one
before it:

| System           | What it does                                                        | State   |
|------------------|---------------------------------------------------------------------|---------|
| `cl-iris/objc`   | Objective-C runtime: classes, selectors, `objc_msgSend`, structs by value, Foundation ⇄ Lisp values, blocks, classes declared with Lisp methods, integer handles, exception reports | working |
| `cl-iris/window` | The `NSApplication` loop on the main thread, `NSWindow`, dispatching work to the main thread through GCD | working |
| `cl-iris/webview`| `WKWebView`; JavaScript → Lisp messages (`WKScriptMessageHandler`), Lisp → JavaScript evaluation, custom URL schemes (`WKURLSchemeHandler`) | working |

The only dependency is CFFI, including `cffi-libffi`, which ships with CFFI
and is needed to pass structs such as `NSRect` by value; building it needs a
C compiler (the Xcode command line tools). See [docs/parity.md](docs/parity.md)
for how cl-iris compares with wry and tao, row by row.

## Getting started

```sh
scripts/bootstrap          # installs SBCL 2.6.9 and qlot under .local/, fetches CFFI
scripts/test               # runs the test suite
```

From a REPL started with `qlot exec sbcl`:

```lisp
(asdf:load-asd (truename "cl-iris.asd"))
(asdf:load-system "cl-iris/objc")

(in-package #:cl-iris/objc)

(with-autorelease-pool
  (lisp-string (send (ns-string "iris") "uppercaseString")))
;; => "IRIS"
```

`send` takes CFFI type/value pairs like `cffi:foreign-funcall`, optionally
followed by the return type (default `:pointer`):

```lisp
(send (ns-string "hello") "length" :unsigned-long)   ; => 5
```

A class can be declared with methods written in Lisp:

```lisp
(define-objc-class "Adder" (:superclass "NSObject")
  (:method "add:to:" :long-long (self (a :long-long) (b :long-long))
    (+ a b)))

(send (send (send (find-class* "Adder") "alloc") "init")
      "add:to:" :long-long 2 :long-long 40 :long-long)
;; => 42
```

Evaluating the form again replaces the methods of the live class, and each
method body is an ordinary function (here named `|Adder add:to:|`), so
redefining it changes the method too.

Foundation values convert to Lisp and back following JSON — strings,
numbers, `T`/`NIL` for booleans, `:null`, vectors and `equal` hash tables —
with `objc->lisp` and `lisp->objc`. Blocks are made from Lisp functions:

```lisp
(define-block-invoker each-object :void
  ((object :pointer) (index :unsigned-long) (stop :pointer)))

(with-block (block (cffi:callback each-object)
                   (lambda (object index stop)
                     (declare (ignore stop))
                     (format t "~D: ~A~%" index (lisp-string object))))
  (send (lisp->objc #("a" "b")) "enumerateObjectsUsingBlock:" :pointer block :void))
```

A block is reference-counted by the Objective-C runtime; the Lisp function
stays reachable exactly as long as some copy of the block does.

### Windows

The main thread runs the Cocoa application; everything else talks to it
through `on-main`, which queues a function on GCD's main queue and, by
default, waits for its values. Window functions call `on-main` themselves,
so they work from any thread — a REPL thread, for instance:

```lisp
(asdf:load-system "cl-iris/window")
(in-package #:cl-iris/window)

;; On the main thread; returns after STOP-APPLICATION.
(run-application
 :on-launch (lambda ()
              (sb-thread:make-thread
               (lambda ()
                 (let ((window (make-window :title "hello" :width 480 :height 300)))
                   (sleep 5)
                   (close-window window)
                   (stop-application))))))
```

An error inside `on-main` is signalled again in the thread that called it.
A waiting caller is never left hanging: it gets `application-not-running`
when the loop is not running, `application-stopped` when the loop ends
first, and `main-thread-timeout` after `:timeout` seconds. For work that
finishes later, in a completion handler, `on-main-deferred` waits for a
reply. `:activation-policy :accessory` runs without a Dock icon, and
`make-window :activate nil` opens a window without taking focus.

### Webviews

```lisp
(asdf:load-system "cl-iris/webview")
(in-package #:cl-iris/webview)

;; From a worker thread, while the main thread is in RUN-APPLICATION:
(let* ((window (cl-iris/window:make-window :title "hello"))
       (webview
         (make-webview
          window
          ;; Pages are served from Lisp under iris://
          :on-request (lambda (url)
                        (declare (ignore url))
                        "<script>
                           window.webkit.messageHandlers.iris.postMessage('hi from ' + location.href)
                         </script>")
          ;; Called on the main thread with what the page posts.
          :on-message (lambda (message) (print message))
          :url "iris://app/index.html")))
  (eval-js webview "document.title = 'set from Lisp'; 1 + 41"))
;; => 42
```

- `on-request` returns a string or octets and, optionally, a content type;
  `nil` answers 404. `fetch()` from the page reaches it too.
- Messages and `eval-js` results convert like other Foundation values, so
  a page can post objects and arrays.
- `eval-js` waits for the result (with an optional `:timeout`); a
  JavaScript exception becomes a `javascript-error`. It cannot wait on the
  main thread (which must run the script) — there, pass `:wait nil` and a
  `:callback`.
- A handler given as a symbol, `:on-message 'my-handler`, follows
  redefinitions of `my-handler`.

## Notes

- AppKit must only be touched from the main thread, which belongs to
  `run-application`. Work for it is identified by an integer, not by a Lisp
  object's address, because the garbage collector may move objects.
- SBCL's floating point traps are masked around everything that runs on the
  main thread (`with-cocoa-float-traps`); Cocoa does not expect them.
- Classes and selectors are looked up by name each time rather than cached
  as pointers, foreign caches are emptied when an image starts, and classes
  declared with `define-objc-class` are declared again, so an image saved
  with `save-lisp-and-die` carries no stale addresses.
- Errors in Lisp code called from Objective-C never unwind into C: they go to
  `report-error`, which calls `*error-reporter*` (printing by default).
- CFFI cannot catch an Objective-C exception, so one that reaches Lisp ends
  the process. `run-application` installs a reporter that prints the
  exception and the Lisp backtrace that led to it first.

## License

Apache License 2.0 — see [LICENSE](LICENSE). If you redistribute cl-iris
or work derived from it, carry the attribution in [NOTICE](NOTICE) along with it.
