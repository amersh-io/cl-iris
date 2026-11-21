;;;; Window objects and their events, delivered through an NSWindowDelegate.
;;;;
;;;; Every window made by MAKE-WINDOW is a WINDOW object with a delegate of
;;;; its own. The objects are kept here by the address of their NSWindow
;;;; (Objective-C objects never move), so a delegate callback, which gets the
;;;; NSWindow, finds the Lisp object. Main thread only.

(in-package #:cl-iris/window)

(defclass window (objc-object)
  ((delegate :initarg :delegate :reader window-delegate
             :documentation "The CLIrisWindowDelegate, retained by this object.")
   (on-event :initform nil :accessor %window-on-event)
   (on-close-request :initform nil :accessor %window-on-close-request)
   (closed :initform nil :accessor %window-closed))
  (:documentation "A window made by MAKE-WINDOW. WINDOW-POINTER is its NSWindow,
which SEND also accepts the window itself in place of."))

(defun window-pointer (window)
  "The NSWindow behind WINDOW, for calling AppKit directly with SEND."
  (objc-object-pointer window))

(defvar *windows* (make-hash-table)
  "WINDOW objects by the address of their NSWindow. Main thread only.")

(defun find-window (window)
  "The live WINDOW object for WINDOW (a WINDOW or its NSWindow pointer), or
NIL once CLOSE-WINDOW has released it."
  (gethash (objc-address window) *windows*))

(define-condition window-closed (error)
  ((window :initarg :window :reader window-closed-window))
  (:report "The window has been closed with CLOSE-WINDOW and can no longer be used."))

(defun on-window (window function)
  "Run FUNCTION on the main thread, as ON-MAIN does, after checking that
WINDOW was made by MAKE-WINDOW and not yet released by CLOSE-WINDOW: a
message to a released window would crash the process."
  (on-main (lambda ()
             (unless (find-window window)
               (error 'window-closed :window window))
             (funcall function))))

(defun notify (window event &rest arguments)
  "Call the event handler of WINDOW (an NSWindow), if it has one, with its
WINDOW object, EVENT and ARGUMENTS."
  (let* ((object (find-window window))
         (handler (and object (%window-on-event object))))
    (when handler
      (apply handler object event arguments))))

(defun notification-window (notification)
  (send notification "object"))

(defun content-size-of (window)
  (let ((frame (send (send window "contentView") "frame" (:struct ns-rect))))
    (values (rect-width frame) (rect-height frame))))

(define-objc-class "CLIrisWindowDelegate" (:protocols ("NSWindowDelegate"))
  (:method "windowShouldClose:" :bool (self (sender :pointer))
    (let* ((object (find-window sender))
           (handler (and object (%window-on-close-request object))))
      (if handler (and (funcall handler object) t) t)))
  (:method "windowWillClose:" :void (self (notification :pointer))
    (let* ((window (notification-window notification))
           (object (find-window window)))
      (when object (setf (%window-closed object) t))
      (notify window :closed)))
  (:method "windowDidResize:" :void (self (notification :pointer))
    (let ((window (notification-window notification)))
      (multiple-value-call #'notify window :resized (content-size-of window))))
  (:method "windowDidMove:" :void (self (notification :pointer))
    (let* ((window (notification-window notification))
           (frame (send window "frame" (:struct ns-rect))))
      (notify window :moved (rect-x frame) (rect-y frame))))
  (:method "windowDidBecomeKey:" :void (self (notification :pointer))
    (notify (notification-window notification) :focused))
  (:method "windowDidResignKey:" :void (self (notification :pointer))
    (notify (notification-window notification) :unfocused))
  (:method "windowDidMiniaturize:" :void (self (notification :pointer))
    (notify (notification-window notification) :minimized))
  (:method "windowDidDeminiaturize:" :void (self (notification :pointer))
    (notify (notification-window notification) :restored))
  (:method "windowDidEnterFullScreen:" :void (self (notification :pointer))
    (notify (notification-window notification) :entered-fullscreen))
  (:method "windowDidExitFullScreen:" :void (self (notification :pointer))
    (notify (notification-window notification) :exited-fullscreen))
  (:method "windowDidChangeBackingProperties:" :void (self (notification :pointer))
    (let ((window (notification-window notification)))
      (notify window :scale-factor-changed (send window "backingScaleFactor" :double)))))

(defun attach-delegate (window)
  "Give WINDOW (an NSWindow) its delegate and WINDOW object, and return the
object. Main thread."
  (let ((delegate (send (send (find-class* "CLIrisWindowDelegate") "alloc") "init")))
    ;; A window does not retain its delegate; the object keeps it alive.
    (send window "setDelegate:" :pointer delegate :void)
    (setf (gethash (objc-address window) *windows*)
          (make-instance 'window :pointer window :delegate delegate))))

(defun detach-delegate (window)
  "Forget WINDOW's delegate and object; true if it had them. Main thread."
  (let ((object (find-window window)))
    (when object
      (send window "setDelegate:" :pointer (cffi:null-pointer) :void)
      (release (window-delegate object))
      (remhash (objc-address window) *windows*)
      t)))

(defun window-event-handler (window)
  "The function SETF WINDOW-EVENT-HANDLER gave WINDOW, or NIL."
  (on-main (lambda () (let ((object (find-window window)))
                        (and object (%window-on-event object))))))

(defun (setf window-event-handler) (handler window)
  "Call HANDLER on the main thread for each event of WINDOW, with the window,
the WINDOW object, the event and its arguments:

  :RESIZED width height     :MOVED x y
  :FOCUSED  :UNFOCUSED      :MINIMIZED  :RESTORED
  :ENTERED-FULLSCREEN  :EXITED-FULLSCREEN
  :SCALE-FACTOR-CHANGED factor
  :CLOSED

HANDLER may be a symbol, called through its current definition. NIL stops
the calls."
  (on-window window (lambda () (setf (%window-on-event (find-window window)) handler)))
  handler)

(defun window-close-request-handler (window)
  "The function SETF WINDOW-CLOSE-REQUEST-HANDLER gave WINDOW, or NIL."
  (on-main (lambda () (let ((object (find-window window)))
                        (and object (%window-on-close-request object))))))

(defun (setf window-close-request-handler) (handler window)
  "When the user asks to close WINDOW (its close button, Cmd+W), call
HANDLER on the main thread with the WINDOW object; the window closes only if it
returns true. NIL lets every request through."
  (on-window window (lambda () (setf (%window-on-close-request (find-window window)) handler)))
  handler)

(defun window-closed-p (window)
  "True once WINDOW has been closed, by the user or by CLOSE-WINDOW."
  (on-main (lambda () (let ((object (find-window window)))
                        (or (null object) (%window-closed object))))))

;;; Windows made by MAKE-WINDOW

(defun windows ()
  "Every window made by MAKE-WINDOW and not yet released by CLOSE-WINDOW,
including those the user has closed."
  (on-main (lambda ()
             (loop for window being the hash-values of *windows*
                   collect window))))

;;; Printing

(defun window-summary (window)
  "WINDOW's title and number, :CLOSED, :RELEASED, or NIL when the main thread
cannot answer within a second (no loop running, or it is busy)."
  (handler-case
      (on-main (lambda ()
                 (let ((object (find-window window)))
                   (cond ((null object) :released)
                         ((%window-closed object) :closed)
                         (t (list (lisp-string (send window "title"))
                                  (send window "windowNumber" :long))))))
               :timeout 1)
    (error () nil)))

(defmethod print-object ((window window) stream)
  (print-unreadable-object (window stream :type t)
    (let ((summary (window-summary window)))
      (if (consp summary)
          (format stream "~S #~D" (first summary) (second summary))
          (format stream "~@[~(~A~) ~]#x~X" summary (objc-address window))))))

(defmethod describe-object ((window window) stream)
  (format stream "~&~S is a window made by MAKE-WINDOW.~%" window)
  (handler-case
      (on-main (lambda ()
                 (let ((object (find-window window)))
                   (cond ((null object)
                          (format stream "  It has been released by CLOSE-WINDOW.~%"))
                         (t
                          (format stream "  Title: ~S~%  Frame: ~S~%  Size: ~S~%  Visible: ~A  Closed: ~A~%"
                                  (window-title window) (window-frame window) (window-size window)
                                  (window-visible-p window) (%window-closed object))
                          (format stream "  Event handler: ~S~%  Close-request handler: ~S~%"
                                  (%window-on-event object) (%window-on-close-request object))
                          (describe-objc (window-pointer window) stream)))))
               :timeout 2)
    (error (e) (format stream "  (The main thread could not answer: ~A)~%" e))))
