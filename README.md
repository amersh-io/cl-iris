# cl-iris

Native windows and webviews for Common Lisp, macOS first.

cl-iris aims to give a running SBCL process an AppKit window with a
`WKWebView` inside it, and a two-way bridge between JavaScript and Lisp,
using nothing but [CFFI](https://cffi.common-lisp.dev/). Everything can be
redefined from the REPL while the window is open.

> **Status:** early. The Objective-C runtime and window layers work; the
> webview layer is next.

## Layers

cl-iris is one repository with several ASDF systems, each built on the one
before it:

| System           | What it does                                                        | State   |
|------------------|---------------------------------------------------------------------|---------|
| `cl-iris/objc`   | Objective-C runtime: classes, selectors, `objc_msgSend`, `NSString`, autorelease pools, classes defined at run time with Lisp methods | working |
| `cl-iris/window` | The `NSApplication` loop on the main thread, `NSWindow`, dispatching work to the main thread through GCD | working |
| `cl-iris/webview`| `WKWebView`; JavaScript → Lisp messages (`WKScriptMessageHandler`), Lisp → JavaScript evaluation, custom URL schemes (`WKURLSchemeHandler`) | planned |

The only dependency is CFFI. `cl-iris/window` also uses `cffi-libffi`, which
ships with CFFI and is needed to pass structs such as `NSRect` by value;
building it needs a C compiler (the Xcode command line tools).

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

A class can be created at run time and given methods written in Lisp:

```lisp
(cffi:defcallback add-to :long-long
    ((self :pointer) (cmd :pointer) (a :long-long) (b :long-long))
  (declare (ignore self cmd))
  (+ a b))

(let ((class (ensure-class "Adder" "NSObject")))
  (set-method class "add:to:" (cffi:callback add-to) "q@:qq")
  (send (send (send class "alloc") "init")
        "add:to:" :long-long 2 :long-long 40 :long-long))
;; => 42
```

`set-method` replaces an existing implementation, so a method can be
redefined while objects of that class are alive.

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

## Notes

- AppKit must only be touched from the main thread, which belongs to
  `run-application`. Work for it is identified by an integer, not by a Lisp
  object's address, because the garbage collector may move objects.
- SBCL's floating point traps are masked around everything that runs on the
  main thread (`with-cocoa-float-traps`); Cocoa does not expect them.
- Classes and selectors are looked up by name each time rather than cached
  as pointers, so an image saved with `save-lisp-and-die` carries no stale
  addresses.
- An Objective-C exception that unwinds through Lisp frames will crash the
  process; nothing catches them yet.

## License

MIT — see [LICENSE](LICENSE).
