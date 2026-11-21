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
  :depends-on ("cffi")
  :pathname "src/objc/"
  :serial t
  :components ((:file "package")
               (:file "runtime")
               (:file "messaging")
               (:file "strings")
               (:file "pool")
               (:file "classes")))

(defsystem "cl-iris/window"
  :description "The NSApplication loop on the main thread, NSWindow, and GCD."
  :license "Apache-2.0"
  :depends-on ("cl-iris/objc" "cffi-libffi")
  :pathname "src/"
  :components ((:file "window")))

(defsystem "cl-iris/webview"
  :description "WKWebView with JavaScript <-> Lisp messaging and custom URL schemes."
  :license "Apache-2.0"
  :depends-on ("cl-iris/window")
  :pathname "src/"
  :components ((:file "webview")))

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
