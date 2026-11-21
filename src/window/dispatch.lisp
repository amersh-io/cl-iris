;;;; Running work on the main thread.

(in-package #:cl-iris/window)

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
