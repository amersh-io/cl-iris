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
           #:window
           #:window-pointer
           #:find-window
           #:make-window
           #:*window-defaults*
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
           #:window-closed-p
           #:window-closed
           #:on-window
           #:windows
           #:window-shadow-p
           #:window-ignores-mouse-p
           #:window-content-protected-p
           #:window-on-all-spaces-p
           #:window-aspect-ratio
           #:run-after
           #:run-every
           #:cancel-timer
           #:timer-cancelled-p
           #:quit-application
           #:system-appearance
           #:theme-change-handler
           #:dock-badge
           #:request-user-attention
           #:cancel-user-attention
           #:hide-application
           #:unhide-application
           #:application-hidden-p
           #:set-menu-bar
           #:find-menu-item
           #:menu-item-enabled-p
           #:menu-item-checked-p
           #:perform-menu-item
           #:application-name
           #:default-menu-bar
           #:screens
           #:main-screen
           #:window-screen
           #:window-scale-factor))
