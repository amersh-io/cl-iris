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
                            (:struct ns-point) (make-point 0 0)
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
