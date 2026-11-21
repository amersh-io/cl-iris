;;;; Macros for the shapes every program and test repeats.

(in-package #:cl-iris/window)

(defun call-with-application (function &rest options)
  "Run the application on this thread, the main thread, and FUNCTION on a
new thread once the loop is running; stop the loop when FUNCTION returns or
unwinds. Return FUNCTION's values, or signal here the condition it signalled.
OPTIONS are those of RUN-APPLICATION, except :ON-LAUNCH."
  (let ((values '())
        (condition nil)
        (thread nil))
    (apply #'run-application
           :on-launch (lambda ()
                        (setf thread
                              (sb-thread:make-thread
                               (lambda ()
                                 (unwind-protect
                                      (handler-case
                                          (setf values (multiple-value-list (funcall function)))
                                        (serious-condition (c) (setf condition c)))
                                   (stop-application)))
                               :name "cl-iris application body")))
           options)
    (when thread
      (sb-thread:join-thread thread :default nil))
    (if condition
        (error condition)
        (values-list values))))

(defmacro with-application ((&rest options) &body body)
  "Run the application on this thread, which must be the main thread, and
BODY on another thread while it runs; the loop stops when BODY is done.
Returns BODY's values; a condition BODY signals is signalled again here.
OPTIONS are those of RUN-APPLICATION, except :ON-LAUNCH.

  (with-application (:activation-policy :accessory)
    (with-window (w :title \"hello\")
      (sleep 5)))"
  `(call-with-application (lambda () ,@body) ,@options))

(defmacro with-window ((var &rest options) &body body)
  "Bind VAR to a window made with MAKE-WINDOW and OPTIONS, run BODY, and close
the window however BODY exits."
  `(let ((,var (make-window ,@options)))
     (unwind-protect (progn ,@body)
       (close-window ,var))))

(defmacro with-main-thread ((&key (wait t) timeout) &body body)
  "Run BODY on the main thread, as ON-MAIN does with WAIT and TIMEOUT: by
default, wait for BODY's values. BODY may use AppKit directly."
  `(on-main (lambda () ,@body) :wait ,wait :timeout ,timeout))
