;;;; Conditions signalled by cl-iris/objc.

(in-package #:cl-iris/objc)

(define-condition objc-error (error)
  ((name :initarg :name :reader objc-error-name
         :documentation "The name of the class or protocol concerned."))
  (:documentation "The root of the errors cl-iris/objc signals. OBJC-ERROR-NAME
is the name of the class or protocol concerned."))

(setf (documentation 'objc-error-name 'function)
      "The name of the class or protocol an OBJC-ERROR is about.")

(define-condition no-such-class (objc-error) ()
  (:documentation "FIND-CLASS* found no Objective-C class of that name.")
  (:report (lambda (c s)
             (format s "No Objective-C class named ~S." (objc-error-name c)))))

(define-condition no-such-protocol (objc-error) ()
  (:documentation "No Objective-C protocol of that name is registered.")
  (:report (lambda (c s)
             (format s "No Objective-C protocol named ~S." (objc-error-name c)))))

(define-condition class-definition-error (objc-error) ()
  (:documentation "The runtime refused to create a class (a name clash, say).")
  (:report (lambda (c s)
             (format s "Could not create the Objective-C class ~S." (objc-error-name c)))))

;;; Errors in callbacks
;;;
;;; A Lisp error must never unwind into Objective-C frames, so every callback
;;; the runtime calls catches its errors and hands them to REPORT-ERROR.

(defvar *error-reporter*
  (lambda (where condition)
    (format *error-output* "~&;; cl-iris: error in ~A: ~A~%" where condition)
    (finish-output *error-output*))
  "A function of two arguments, a description of where the error happened and
the condition, called for errors caught in callbacks from Objective-C.")

(defun report-error (where condition)
  "Hand CONDITION, caught in a callback, to *ERROR-REPORTER*. An error inside
the reporter itself is dropped rather than allowed to unwind into C."
  (ignore-errors (funcall *error-reporter* where condition))
  nil)
