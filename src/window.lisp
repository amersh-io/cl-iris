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

(in-package #:cl-iris/window)

(cffi:define-foreign-library appkit
  (:darwin "/System/Library/Frameworks/AppKit.framework/AppKit"))

(cffi:use-foreign-library appkit)

;;; NSRect and NSPoint are passed by value, which needs cffi-libffi. The flat
;;; layouts below have the same size and alignment as the nested Cocoa ones.

(cffi:defcstruct ns-point
  (x :double)
  (y :double))

(cffi:defcstruct ns-rect
  (x :double)
  (y :double)
  (width :double)
  (height :double))

(defun rect (x y width height)
  (list 'x (float x 1d0) 'y (float y 1d0)
        'width (float width 1d0) 'height (float height 1d0)))

;;; Floating point traps
;;;
;;; SBCL enables FP traps that Cocoa does not expect; AppKit and WebKit would
;;; otherwise raise FLOATING-POINT-INVALID-OPERATION and friends inside Lisp.

(defmacro with-cocoa-float-traps (&body body)
  "Run BODY with the floating point traps Cocoa relies on being masked."
  `(sb-int:with-float-traps-masked
       (:overflow :invalid :divide-by-zero :inexact :underflow)
     ,@body))

;;; The main thread

(defun main-thread-p ()
  "True when called on the process's main thread."
  (= 1 (cffi:foreign-funcall "pthread_main_np" :int)))

;;; Work queued for the main thread is kept here under an integer id, and only
;;; the id crosses into C: the garbage collector may move Lisp objects, so no
;;; Lisp object's address is ever handed to the Objective-C side.

(defvar *tasks* (make-hash-table))
(defvar *tasks-lock* (sb-thread:make-mutex :name "cl-iris tasks"))
(defvar *next-task-id* 0)

(defun register-task (function)
  (sb-thread:with-mutex (*tasks-lock*)
    (let ((id (incf *next-task-id*)))
      (setf (gethash id *tasks*) function)
      id)))

(defun take-task (id)
  (sb-thread:with-mutex (*tasks-lock*)
    (prog1 (gethash id *tasks*)
      (remhash id *tasks*))))

(cffi:defcallback run-task :void ((context :pointer))
  (let ((task (take-task (cffi:pointer-address context))))
    (when task
      (with-cocoa-float-traps
        (with-autorelease-pool
          (funcall task))))))

(defun dispatch-to-main (function)
  (cffi:foreign-funcall "dispatch_async_f"
                        :pointer (cffi:foreign-symbol-pointer "_dispatch_main_q")
                        :pointer (cffi:make-pointer (register-task function))
                        :pointer (cffi:callback run-task)
                        :void))

(defun on-main (function &key (wait t))
  "Run FUNCTION on the main thread.

With WAIT (the default), block until it has run and return its values; a
condition it signals is signalled again in the calling thread. Called on the
main thread with WAIT, FUNCTION simply runs in place.

Without WAIT, queue FUNCTION and return NIL at once. An error it signals is
reported on *ERROR-OUTPUT*, since there is nobody left to return it to.

Queued work runs only while the main thread is in RUN-APPLICATION."
  (cond ((not wait)
         (dispatch-to-main
          (lambda ()
            (handler-case (funcall function)
              (serious-condition (c)
                (format *error-output* "~&;; cl-iris: error on the main thread: ~A~%" c)))))
         nil)
        ((main-thread-p)
         (with-cocoa-float-traps
           (with-autorelease-pool
             (funcall function))))
        (t
         (let ((done (sb-thread:make-semaphore :name "cl-iris on-main"))
               (values '())
               (condition nil))
           (dispatch-to-main
            (lambda ()
              (unwind-protect
                   (handler-case (setf values (multiple-value-list (funcall function)))
                     (serious-condition (c) (setf condition c)))
                (sb-thread:signal-semaphore done))))
           (sb-thread:wait-on-semaphore done)
           (if condition
               (error condition)
               (values-list values))))))

;;; The application

(defun app ()
  (send (find-class* "NSApplication") "sharedApplication"))

(defun activation-policy-value (policy)
  (ecase policy
    (:regular 0)      ; a Dock icon and a menu bar, like any application
    (:accessory 1)    ; no Dock icon; windows still show
    (:prohibited 2))) ; no windows at all
(defconstant +event-type-application-defined+ 15)

(defun run-application (&key on-launch (activation-policy :regular))
  "Run the Cocoa application on the main thread until STOP-APPLICATION.
ON-LAUNCH, if given, is called on the main thread once the loop is running.
ACTIVATION-POLICY is :REGULAR, :ACCESSORY (no Dock icon) or :PROHIBITED.
Must be called on the main thread."
  (unless (main-thread-p)
    (error "RUN-APPLICATION must be called on the main thread."))
  (with-cocoa-float-traps
    (with-autorelease-pool
      (let ((app (app)))
        (send app "setActivationPolicy:"
              :long (activation-policy-value activation-policy) :bool)
        (when on-launch
          (on-main on-launch :wait nil))
        (send app "run" :void)))))

(defun stop-application ()
  "Make RUN-APPLICATION return. Callable from any thread."
  (on-main
   (lambda ()
     (let ((app (app)))
       (send app "stop:" :pointer (cffi:null-pointer) :void)
       ;; -stop: takes effect only after the next event, so post one.
       (send app "postEvent:atStart:"
             :pointer (send (find-class* "NSEvent")
                            "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"
                            :unsigned-long +event-type-application-defined+
                            (:struct ns-point) (list 'x 0d0 'y 0d0)
                            :unsigned-long 0
                            :double 0d0
                            :long 0
                            :pointer (cffi:null-pointer)
                            :short 0
                            :long 0
                            :long 0)
             :bool t
             :void))))
  nil)

;;; Windows

(defconstant +window-style+ (logior 1 2 4 8)
  "Titled, closable, miniaturizable and resizable.")

(defconstant +backing-store-buffered+ 2)

(defun make-window (&key (title "") (x 200) (y 200) (width 800) (height 600)
                      (activate t))
  "Open a window whose content area is WIDTH by HEIGHT points, with its
bottom-left corner at X, Y on the screen, and return it. With ACTIVATE, the
application is brought to the front; without it, the window opens without
taking focus from other applications."
  (on-main
   (lambda ()
     (let ((window (send (send (find-class* "NSWindow") "alloc")
                         "initWithContentRect:styleMask:backing:defer:"
                         (:struct ns-rect) (rect x y width height)
                         :unsigned-long +window-style+
                         :unsigned-long +backing-store-buffered+
                         ;; BOOL as a byte: once a struct is passed by value
                         ;; the call goes through libffi, which rejects :BOOL.
                         :unsigned-char 0)))
       ;; We release the window ourselves in CLOSE-WINDOW.
       (send window "setReleasedWhenClosed:" :bool nil :void)
       (send window "setTitle:" :pointer (ns-string title) :void)
       (send window "makeKeyAndOrderFront:" :pointer (cffi:null-pointer) :void)
       (when activate
         (send (app) "activateIgnoringOtherApps:" :bool t :void))
       window))))

(defun close-window (window)
  "Close WINDOW and release it."
  (on-main
   (lambda ()
     (send window "close" :void)
     (send window "release" :void)))
  nil)

(defun window-number (window)
  "The window server's number for WINDOW, as used by screencapture -l."
  (on-main (lambda () (send window "windowNumber" :long))))

(defun window-title (window)
  (on-main (lambda () (lisp-string (send window "title")))))

(defun window-content-size (window)
  "Return the width and height of WINDOW's content area, in points."
  (on-main
   (lambda ()
     (let ((frame (send (send window "contentView") "frame" (:struct ns-rect))))
       (values (getf frame 'width) (getf frame 'height))))))
