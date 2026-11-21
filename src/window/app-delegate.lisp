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

(defvar *window-closed-this-loop* nil
  "True once a window has closed during the current RUN-APPLICATION loop.
AppKit may ask whether to quit after the last window closed in an earlier
loop; only a close in this loop counts.")

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
    (and *quit-on-last-window-closed* *window-closed-this-loop* t)))

(defun quit-application ()
  "Ask to quit, as the Quit menu item does: the quit request handler decides
whether the loop stops."
  (on-main (lambda () (send (app) "terminate:" :pointer (cffi:null-pointer) :void)))
  nil)

;;; The system's light or dark appearance

(defun system-appearance ()
  "The appearance the user chose for the system: :LIGHT or :DARK."
  (on-main
   (lambda ()
     (let ((style (send (send (find-class* "NSUserDefaults") "standardUserDefaults")
                        "stringForKey:" :pointer (ns-string "AppleInterfaceStyle"))))
       (if (and (not (cffi:null-pointer-p style))
                (string-equal "Dark" (lisp-string style)))
           :dark
           :light)))))

(defparameter *theme-notification* "AppleInterfaceThemeChangedNotification")

(defvar *on-theme-change* nil)
(defvar *theme-observer* nil)

(define-objc-class "CLIrisThemeObserver" ()
  (:method "themeChanged:" :void (self (notification :pointer))
    (declare (ignore notification))
    (when *on-theme-change*
      (funcall *on-theme-change* (system-appearance)))))

(defun distributed-center ()
  (send (find-class* "NSDistributedNotificationCenter") "defaultCenter"))

(defun theme-change-handler ()
  *on-theme-change*)

(defun (setf theme-change-handler) (handler)
  "Call HANDLER on the main thread with :LIGHT or :DARK whenever the user
switches the system's appearance. NIL stops the calls."
  (on-main
   (lambda ()
     (setf *on-theme-change* handler)
     (cond ((and handler (not *theme-observer*))
            (setf *theme-observer* (send (send (find-class* "CLIrisThemeObserver") "alloc") "init"))
            (send (distributed-center) "addObserver:selector:name:object:"
                  :pointer *theme-observer* :pointer (selector "themeChanged:")
                  :pointer (ns-string *theme-notification*) :pointer (cffi:null-pointer)
                  :void))
           ((and (not handler) *theme-observer*)
            (send (distributed-center) "removeObserver:" :pointer *theme-observer* :void)
            (release *theme-observer*)
            (setf *theme-observer* nil)))))
  handler)
