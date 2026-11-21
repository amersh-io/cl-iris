;;;; cl-iris -- native windows and webviews for Common Lisp.

(defsystem "cl-iris"
  :description "Native windows and webviews for Common Lisp (macOS first)."
  :license "MIT"
  :version "0.0.1"
  :homepage "https://github.com/amersh-io/cl-iris"
  :depends-on ("cl-iris/objc" "cl-iris/window")
  :in-order-to ((test-op (test-op "cl-iris/test"))))

(defsystem "cl-iris/objc"
  :description "A thin CFFI binding to the Objective-C runtime."
  :license "MIT"
  :depends-on ("cffi")
  :pathname "src/"
  :components ((:file "objc")))

(defsystem "cl-iris/window"
  :description "The NSApplication loop on the main thread, NSWindow, and GCD."
  :license "MIT"
  :depends-on ("cl-iris/objc" "cffi-libffi")
  :pathname "src/"
  :components ((:file "window")))

(defsystem "cl-iris/test"
  :license "MIT"
  :depends-on ("cl-iris/objc" "cl-iris/window")
  :pathname "test/"
  :serial t
  :components ((:file "package")
               (:file "objc")
               (:file "window")
               (:file "run"))
  :perform (test-op (o c) (symbol-call :cl-iris/test :run!)))
