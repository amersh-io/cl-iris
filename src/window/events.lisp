;;;; Window events, delivered through an NSWindowDelegate.
;;;;
;;;; Every window made by MAKE-WINDOW gets a delegate of its own. The Lisp
;;;; functions it calls are kept here by the window's address (Objective-C
;;;; objects never move), and only touched on the main thread.

(in-package #:cl-iris/window)

(defstruct (window-record (:constructor make-window-record (delegate)))
  delegate                              ; the CLIrisWindowDelegate, retained by us
  (on-event nil)
  (on-close-request nil)
  (closed nil))

(defvar *windows* (make-hash-table)
  "Window records by the address of their NSWindow. Main thread only.")

(defun window-record (window)
  (gethash (cffi:pointer-address window) *windows*))

(define-condition window-closed (error)
  ((window :initarg :window :reader window-closed-window))
  (:report "The window has been closed with CLOSE-WINDOW and can no longer be used."))

(defun on-window (window function)
  "Run FUNCTION on the main thread, as ON-MAIN does, after checking that
WINDOW was made by MAKE-WINDOW and not yet released by CLOSE-WINDOW: a
message to a released window would crash the process."
  (on-main (lambda ()
             (unless (window-record window)
               (error 'window-closed :window window))
             (funcall function))))

(defun notify (window event &rest arguments)
  "Call WINDOW's event handler, if it has one, with EVENT and ARGUMENTS."
  (let* ((record (window-record window))
         (handler (and record (window-record-on-event record))))
    (when handler
      (apply handler window event arguments))))

(defun notification-window (notification)
  (send notification "object"))

(defun content-size-of (window)
  (let ((frame (send (send window "contentView") "frame" (:struct ns-rect))))
    (values (rect-width frame) (rect-height frame))))

(define-objc-class "CLIrisWindowDelegate" (:protocols ("NSWindowDelegate"))
  (:method "windowShouldClose:" :bool (self (sender :pointer))
    (let* ((record (window-record sender))
           (handler (and record (window-record-on-close-request record))))
      (if handler (and (funcall handler sender) t) t)))
  (:method "windowWillClose:" :void (self (notification :pointer))
    (let* ((window (notification-window notification))
           (record (window-record window)))
      (when record (setf (window-record-closed record) t))
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
  "Give WINDOW its delegate and record. Main thread."
  (let ((delegate (send (send (find-class* "CLIrisWindowDelegate") "alloc") "init")))
    ;; A window does not retain its delegate; the record keeps it alive.
    (send window "setDelegate:" :pointer delegate :void)
    (setf (gethash (cffi:pointer-address window) *windows*) (make-window-record delegate))))

(defun detach-delegate (window)
  "Forget WINDOW's delegate and record; true if it had them. Main thread."
  (let ((record (window-record window)))
    (when record
      (send window "setDelegate:" :pointer (cffi:null-pointer) :void)
      (release (window-record-delegate record))
      (remhash (cffi:pointer-address window) *windows*)
      t)))

(defun window-event-handler (window)
  (on-main (lambda () (let ((record (window-record window)))
                        (and record (window-record-on-event record))))))

(defun (setf window-event-handler) (handler window)
  "Call HANDLER on the main thread for each event of WINDOW, with the window,
the event and its arguments:

  :RESIZED width height     :MOVED x y
  :FOCUSED  :UNFOCUSED      :MINIMIZED  :RESTORED
  :ENTERED-FULLSCREEN  :EXITED-FULLSCREEN
  :SCALE-FACTOR-CHANGED factor
  :CLOSED

HANDLER may be a symbol, called through its current definition. NIL stops
the calls."
  (on-window window (lambda () (setf (window-record-on-event (window-record window)) handler)))
  handler)

(defun window-close-request-handler (window)
  (on-main (lambda () (let ((record (window-record window)))
                        (and record (window-record-on-close-request record))))))

(defun (setf window-close-request-handler) (handler window)
  "When the user asks to close WINDOW (its close button, Cmd+W), call
HANDLER on the main thread with the window; the window closes only if it
returns true. NIL lets every request through."
  (on-window window (lambda () (setf (window-record-on-close-request (window-record window)) handler)))
  handler)

(defun window-closed-p (window)
  "True once WINDOW has been closed, by the user or by CLOSE-WINDOW."
  (on-main (lambda () (let ((record (window-record window)))
                        (or (null record) (window-record-closed record))))))

;;; Windows made by MAKE-WINDOW

(defun windows ()
  "Every window made by MAKE-WINDOW and not yet released by CLOSE-WINDOW,
including those the user has closed."
  (on-main (lambda ()
             (loop for address being the hash-keys of *windows*
                   collect (cffi:make-pointer address)))))
