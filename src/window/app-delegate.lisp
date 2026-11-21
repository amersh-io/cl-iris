;;;; The application's delegate: quitting, reopening, the last window.
;;;;
;;;; AppKit's own Quit (Cmd+Q, the Dock's Quit, logging out) would end the
;;;; process with exit(). Here it asks the Lisp handler instead, and an
;;;; accepted request stops the loop, so RUN-APPLICATION returns and the Lisp
;;;; program decides what happens next.

(in-package #:cl-iris/window)

(defvar *on-quit-request* (constantly t)
  "Called with no arguments when the user asks to quit; true lets the loop stop.")

(defvar *on-reopen* nil
  "Called with one argument, whether any window is visible, when the user
clicks the Dock icon or opens the running application again.")

(defvar *quit-on-last-window-closed* nil
  "True to treat closing the last window as a request to quit.")

(defconstant +terminate-cancel+ 0)

(define-objc-class "CLIrisApplicationDelegate" (:protocols ("NSApplicationDelegate"))
  (:method "applicationShouldTerminate:" :unsigned-long (self (sender :pointer))
    (declare (ignore sender))
    (when (funcall *on-quit-request*)
      (stop-loop))
    ;; Never let AppKit end the process itself.
    +terminate-cancel+)
  (:method "applicationShouldHandleReopen:hasVisibleWindows:" :bool
      (self (sender :pointer) (visible :bool))
    (declare (ignore sender))
    (when *on-reopen*
      (funcall *on-reopen* visible))
    t)
  (:method "applicationShouldTerminateAfterLastWindowClosed:" :bool (self (sender :pointer))
    (declare (ignore sender))
    (and *quit-on-last-window-closed* t)))

(defun quit-application ()
  "Ask to quit, as the Quit menu item does: the quit request handler decides
whether the loop stops."
  (on-main (lambda () (send (app) "terminate:" :pointer (cffi:null-pointer) :void)))
  nil)
