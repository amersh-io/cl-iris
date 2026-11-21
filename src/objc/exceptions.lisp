;;;; Reporting Objective-C exceptions.
;;;;
;;;; CFFI cannot catch an Objective-C exception, and it cannot unwind through
;;;; Lisp frames, so one that escapes into Lisp ends the process. What we can
;;;; do is say why first: the uncaught exception handler prints the
;;;; exception's name and reason, and the Lisp backtrace that led to it, just
;;;; before the runtime aborts.

(in-package #:cl-iris/objc)

(cffi:defcallback report-uncaught-exception :void ((exception :pointer))
  (ignore-errors
   (let ((out *error-output*))
     (format out "~&;; cl-iris: uncaught Objective-C exception ~A: ~A~%"
             (lisp-string (send exception "name"))
             (lisp-string (send exception "reason")))
     (format out ";; The process will abort. Lisp backtrace:~%")
     (sb-debug:print-backtrace :count 30 :stream out)
     (finish-output out))))

(defun install-exception-reporter ()
  "Print the name, reason and Lisp backtrace of any Objective-C exception that
is about to end the process. RUN-APPLICATION calls this."
  (cffi:foreign-funcall "NSSetUncaughtExceptionHandler"
                        :pointer (cffi:callback report-uncaught-exception)
                        :void))
