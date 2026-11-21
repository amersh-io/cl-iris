;;;; Running work on the main thread.

(in-package #:cl-iris/window)

;;; The main thread

(defun main-thread-p ()
  "True when called on the process's main thread."
  (= 1 (cffi:foreign-funcall "pthread_main_np" :int)))

;;; Work queued for the main thread is registered as a handle (see
;;; cl-iris/objc), and only the handle crosses into C.

(cffi:defcallback run-task :void ((context :pointer))
  (let ((task (take-handle (cffi:pointer-address context))))
    (when task
      (with-cocoa-float-traps
        (with-autorelease-pool
          (funcall task))))))

(defun dispatch-to-main (function)
  "Queue FUNCTION on the main queue; return the handle it is queued under."
  (let ((handle (make-handle function)))
    (cffi:foreign-funcall "dispatch_async_f"
                          :pointer (cffi:foreign-symbol-pointer "_dispatch_main_q")
                          :pointer (cffi:make-pointer handle)
                          :pointer (cffi:callback run-task)
                          :void)
    handle))

;;; Waiting for the main thread
;;;
;;; A thread that waits for the main thread must not wait forever: the loop
;;; may not be running yet, may stop while the work is still queued, or may
;;; never get to it in time. Every waiting caller registers a waiter; the
;;; loop's end wakes all of them, and a timeout withdraws the queued work.

(define-condition main-thread-error (error) ()
  (:documentation "The root of the errors about running work on the main thread."))

(define-condition application-not-running (main-thread-error) ()
  (:report "The application loop is not running, so the main thread cannot run the work."))

(define-condition application-stopped (main-thread-error) ()
  (:report "The application loop stopped before the work on the main thread finished."))

(define-condition main-thread-timeout (main-thread-error)
  ((seconds :initarg :seconds :reader main-thread-timeout-seconds))
  (:report (lambda (c s)
             (format s "The main thread did not finish the work within ~A seconds."
                     (main-thread-timeout-seconds c)))))

(defvar *dispatch-lock* (sb-thread:make-mutex :name "cl-iris dispatch"))
(defvar *running* nil "True while RUN-APPLICATION is in its loop.")
(defvar *waiters* '() "Waiters whose work has not delivered a result yet.")

(defstruct (waiter (:constructor %make-waiter))
  (semaphore (sb-thread:make-semaphore :name "cl-iris waiter"))
  (task nil)                            ; handle of the queued work
  (done nil)
  (values '())
  (condition nil))

(defun deliver (waiter &key values condition)
  "Give WAITER its result, unless it already has one. Returns true if it did."
  (sb-thread:with-mutex (*dispatch-lock*)
    (unless (waiter-done waiter)
      (setf (waiter-done waiter) t
            (waiter-values waiter) values
            (waiter-condition waiter) condition
            *waiters* (delete waiter *waiters*))
      (sb-thread:signal-semaphore (waiter-semaphore waiter))
      t)))

(defun wake-all-waiters ()
  "Called when the loop ends: work not yet run is withdrawn and every waiter
gets APPLICATION-STOPPED."
  (dolist (waiter (sb-thread:with-mutex (*dispatch-lock*) (copy-list *waiters*)))
    (take-handle (waiter-task waiter))
    (deliver waiter :condition (make-condition 'application-stopped))))

(defun call-and-wait (function timeout)
  "Queue FUNCTION, called with a waiter, and wait for that waiter's result."
  (let ((waiter (%make-waiter)))
    ;; Queue under the lock, so the loop's end either sees the waiter with
    ;; its task or happens before it and is reported at once.
    (sb-thread:with-mutex (*dispatch-lock*)
      (unless *running*
        (error 'application-not-running))
      (push waiter *waiters*)
      (setf (waiter-task waiter)
            (dispatch-to-main
             (lambda ()
               (handler-case (funcall function waiter)
                 (serious-condition (c) (deliver waiter :condition c)))))))
    (unless (sb-thread:wait-on-semaphore (waiter-semaphore waiter) :timeout timeout)
      (take-handle (waiter-task waiter))
      (deliver waiter :condition (make-condition 'main-thread-timeout :seconds timeout)))
    (if (waiter-condition waiter)
        (error (waiter-condition waiter))
        (values-list (waiter-values waiter)))))

(defun on-main (function &key (wait t) timeout)
  "Run FUNCTION on the main thread.

With WAIT (the default), block until it has run and return its values; a
condition it signals is signalled again in the calling thread. Called on the
main thread with WAIT, FUNCTION simply runs in place. Waiting signals
APPLICATION-NOT-RUNNING when the loop is not running, APPLICATION-STOPPED
when it stops first, and MAIN-THREAD-TIMEOUT after TIMEOUT seconds (if
given); in the last two cases FUNCTION does not run if it has not started.

Without WAIT, queue FUNCTION and return NIL at once; it runs whenever the
loop next runs. An error it signals is handed to REPORT-ERROR, since there is
nobody left to return it to."
  (cond ((not wait)
         (dispatch-to-main
          (lambda ()
            (handler-case (funcall function)
              (serious-condition (c) (report-error "work queued on the main thread" c)))))
         nil)
        ((main-thread-p)
         (with-cocoa-float-traps
           (with-autorelease-pool
             (funcall function))))
        (t
         (call-and-wait (lambda (waiter)
                          (deliver waiter :values (multiple-value-list (funcall function))))
                        timeout))))

(defun on-main-deferred (function &key timeout)
  "Run FUNCTION on the main thread with two arguments, REPLY and FAIL, and
wait until it calls one of them, possibly later from a callback: REPLY with
the values to return, FAIL with a condition to signal. Waits the way ON-MAIN
does, with the same conditions. Cannot be called on the main thread, which
would have to wait for itself."
  (when (main-thread-p)
    (error "ON-MAIN-DEFERRED cannot wait on the main thread."))
  (call-and-wait (lambda (waiter)
                   (funcall function
                            (lambda (&rest values) (deliver waiter :values values))
                            (lambda (condition) (deliver waiter :condition condition))))
                 timeout))
