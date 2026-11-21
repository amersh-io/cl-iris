;;;; cl-iris -- native windows and webviews for Common Lisp.

(defsystem "cl-iris"
  :description "Native windows and webviews for Common Lisp (macOS first)."
  :license "Apache-2.0"
  :version "0.0.1"
  :homepage "https://github.com/amersh-io/cl-iris"
  :depends-on ("cl-iris/objc" "cl-iris/window" "cl-iris/webview")
  :in-order-to ((test-op (test-op "cl-iris/test"))))

(defsystem "cl-iris/objc"
  :description "A thin CFFI binding to the Objective-C runtime."
  :license "Apache-2.0"
  :depends-on ("cffi" "cffi-libffi")
  :pathname "src/objc/"
  :serial t
  :components ((:file "package")
               (:file "conditions")
               (:file "handles")
               (:file "runtime")
               (:file "messaging")
               (:file "geometry")
               (:file "strings")
               (:file "convert")
               (:file "pool")
               (:file "classes")
               (:file "blocks")
               (:file "exceptions")))

(defsystem "cl-iris/window"
  :description "The NSApplication loop on the main thread, NSWindow, and GCD."
  :license "Apache-2.0"
  :depends-on ("cl-iris/objc")
  :pathname "src/window/"
  :serial t
  :components ((:file "package")
               (:file "runtime")
               (:file "traps")
               (:file "dispatch")
               (:file "timers")
               (:file "app-delegate")
               (:file "menu")
               (:file "application")
               (:file "color")
               (:file "events")
               (:file "attributes")
               (:file "window")
               (:file "screens")))

(defsystem "cl-iris/webview"
  :description "WKWebView with JavaScript <-> Lisp messaging and custom URL schemes."
  :license "Apache-2.0"
  :depends-on ("cl-iris/window")
  :pathname "src/webview/"
  :serial t
  :components ((:file "package")
               (:file "runtime")
               (:file "scheme")
               (:file "ipc")
               (:file "navigation")
               (:file "delegate")
               (:file "options")
               (:file "webview")
               (:file "history")
               (:file "eval")))

(defsystem "cl-iris/test"
  :license "Apache-2.0"
  :depends-on ("cl-iris/objc" "cl-iris/window" "cl-iris/webview")
  :pathname "test/"
  :serial t
  :components ((:file "package")
               (:file "objc")
               (:file "window")
               (:file "webview")
               (:file "run"))
  :perform (test-op (o c) (symbol-call :cl-iris/test :run!)))
