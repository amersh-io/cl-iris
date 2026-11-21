;;;; Timers: running work on the main thread later, once or repeatedly.
;;;;
;;;; Built on dispatch_after_f and the main queue, like ON-MAIN, so timers
;;;; fire only while the application loop runs. A timer is registered as one
;;;; handle for its whole life; cancelling marks it, and the next firing
;;;; releases the handle instead of calling the function.

(in-package #:cl-iris/window)

(defstruct (timer (:constructor %make-timer (function interval)))
  function
  interval                              ; seconds between firings, or NIL
  (handle nil)
  (cancelled nil))

(defun arm (timer seconds)
  (cffi:foreign-funcall "dispatch_after_f"
                        :uint64 (cffi:foreign-funcall "dispatch_time"
                                                      :uint64 0 ; DISPATCH_TIME_NOW
                                                      :int64 (round (* seconds 1d9))
                                                      :uint64)
                        :pointer (cffi:foreign-symbol-pointer "_dispatch_main_q")
                        :pointer (cffi:make-pointer (timer-handle timer))
                        :pointer (cffi:callback fire-timer)
                        :void))

(cffi:defcallback fire-timer :void ((context :pointer))
  (let ((timer (handle-value (cffi:pointer-address context))))
    (when timer
      (cond ((timer-cancelled timer)
             (release-handle (timer-handle timer)))
            (t
             (with-cocoa-float-traps
               (with-autorelease-pool
                 (handler-case (funcall (timer-function timer))
                   (serious-condition (c) (report-error "a timer" c)))))
             (if (and (timer-interval timer) (not (timer-cancelled timer)))
                 (arm timer (timer-interval timer))
                 (release-handle (timer-handle timer))))))))

(defun start-timer (function delay interval)
  (check-type delay (real 0))
  (let ((timer (%make-timer function interval)))
    (setf (timer-handle timer) (make-handle timer))
    (arm timer delay)
    timer))

(defun run-after (seconds function)
  "Call FUNCTION on the main thread once, SECONDS from now. Returns a timer
for CANCEL-TIMER."
  (start-timer function seconds nil))

(defun run-every (seconds function &key (delay seconds))
  "Call FUNCTION on the main thread every SECONDS, the first time DELAY
seconds from now, until CANCEL-TIMER. An error in FUNCTION is reported and
does not stop the timer."
  (check-type seconds (real (0)))
  (start-timer function delay seconds))

(defun cancel-timer (timer)
  "Stop TIMER from calling its function again. Callable from any thread,
including from inside the function."
  (setf (timer-cancelled timer) t)
  nil)

(defun timer-cancelled-p (timer)
  "True once CANCEL-TIMER has stopped TIMER."
  (timer-cancelled timer))
