;;;; The NSApplication loop.

(in-package #:cl-iris/window)

;;; The application

(defun app ()
  (send (find-class* "NSApplication") "sharedApplication"))

(defun activation-policy-value (policy)
  (ecase policy
    (:regular 0)      ; a Dock icon and a menu bar, like any application
    (:accessory 1)    ; no Dock icon; windows still show
    (:prohibited 2))) ; no windows at all
(defconstant +event-type-application-defined+ 15)

(defun run-application (&key on-launch (activation-policy :regular)
                          (on-quit-request (constantly t)) on-reopen
                          quit-on-last-window-closed)
  "Run the Cocoa application on the main thread until STOP-APPLICATION.
ON-LAUNCH, if given, is called on the main thread once the loop is running.
ACTIVATION-POLICY is :REGULAR, :ACCESSORY (no Dock icon) or :PROHIBITED.

When the user asks to quit (Cmd+Q, the Dock), ON-QUIT-REQUEST is called on
the main thread and the loop stops if it returns true; the process itself
never exits behind Lisp's back. ON-REOPEN is called with whether any window
is visible when the user clicks the Dock icon. With
QUIT-ON-LAST-WINDOW-CLOSED, closing the last window counts as a request to
quit.

Must be called on the main thread."
  (unless (main-thread-p)
    (error "RUN-APPLICATION must be called on the main thread."))
  (sb-thread:with-mutex (*dispatch-lock*)
    (when *running*
      (error "The application loop is already running."))
    (setf *running* t))
  (install-exception-reporter)
  (unwind-protect
       ;; Bound here: the delegate's callbacks run on this thread, inside
       ;; [NSApp run], and so see these bindings.
       (let ((*on-quit-request* on-quit-request)
             (*on-reopen* on-reopen)
             (*quit-on-last-window-closed* quit-on-last-window-closed))
         (with-cocoa-float-traps
           (with-autorelease-pool
             (let ((app (app))
                   (delegate (send (send (find-class* "CLIrisApplicationDelegate") "alloc")
                                   "init")))
               (send app "setActivationPolicy:"
                     :long (activation-policy-value activation-policy) :bool)
               (send app "setDelegate:" :pointer delegate :void)
               (when on-launch
                 (on-main on-launch :wait nil))
               (unwind-protect (send app "run" :void)
                 (send app "setDelegate:" :pointer (cffi:null-pointer) :void)
                 (release delegate))))))
    (sb-thread:with-mutex (*dispatch-lock*)
      (setf *running* nil))
    (wake-all-waiters)))

(defun application-running-p ()
  "True while RUN-APPLICATION is running the loop."
  *running*)

(defun stop-application ()
  "Make RUN-APPLICATION return. Callable from any thread; does nothing when
the loop is not running."
  (when (application-running-p)
    ;; The loop may end on its own while we ask it to; that is fine.
    (handler-case (stop-loop)
      (main-thread-error () nil)))
  nil)

(defun stop-loop ()
  (on-main
   (lambda ()
     (let ((app (app)))
       (send app "stop:" :pointer (cffi:null-pointer) :void)
       ;; -stop: takes effect only after the next event, so post one.
       (send app "postEvent:atStart:"
             :pointer (send (find-class* "NSEvent")
                            "otherEventWithType:location:modifierFlags:timestamp:windowNumber:context:subtype:data1:data2:"
                            :unsigned-long +event-type-application-defined+
                            (:struct ns-point) (make-point 0 0)
                            :unsigned-long 0
                            :double 0d0
                            :long 0
                            :pointer (cffi:null-pointer)
                            :short 0
                            :long 0
                            :long 0)
             :bool t
             :void)))))
