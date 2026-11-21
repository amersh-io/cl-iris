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
           #:on-main-deferred
           #:main-thread-error
           #:application-not-running
           #:application-stopped
           #:main-thread-timeout
           #:application-running-p
           #:with-cocoa-float-traps
           #:run-application
           #:stop-application
           #:make-window
           #:close-window
           #:window-number
           #:window-title
           #:window-content-size
           #:resize-window
           #:window-frame
           #:window-position
           #:move-window
           #:center-window
           #:window-min-size
           #:set-window-min-size
           #:window-max-size
           #:set-window-max-size
           #:window-style
           #:window-resizable-p
           #:window-decorated-p
           #:window-level
           #:show-window
           #:hide-window
           #:window-visible-p
           #:activate-application
           #:focus-window
           #:window-focused-p
           #:minimize-window
           #:restore-window
           #:window-minimized-p
           #:window-maximized-p
           #:window-fullscreen-p
           #:color-components
           #:ns-color
           #:ns-color-components
           #:window-alpha
           #:window-background-color
           #:window-transparent-p
           #:window-appearance
           #:window-title-visible-p
           #:window-titlebar-transparent-p
           #:window-event-handler
           #:window-close-request-handler
           #:window-closed-p))
