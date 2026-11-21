;;;; cl-iris/window -- the NSApplication loop, the main thread and NSWindow.
;;;;
;;;; AppKit may only be used from the main thread, and the main thread spends
;;;; its life inside [NSApp run]. Other threads hand it work through GCD's main
;;;; queue with ON-MAIN. Every public function here that touches AppKit goes
;;;; through ON-MAIN, so it can be called from any thread, e.g. a REPL thread.

(defpackage #:cl-iris/window
  (:use #:cl #:cl-iris/objc)
  (:export #:main-thread-p
           #:on-main
           #:with-cocoa-float-traps
           #:run-application
           #:stop-application
           #:make-window
           #:close-window
           #:window-number
           #:window-title
           #:window-content-size))
