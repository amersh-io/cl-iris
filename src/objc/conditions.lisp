;;;; Conditions signalled by cl-iris/objc.

(in-package #:cl-iris/objc)

(define-condition objc-error (error)
  ((name :initarg :name :reader objc-error-name))
  (:documentation "The root of the errors cl-iris/objc signals."))

(define-condition no-such-class (objc-error) ()
  (:report (lambda (c s)
             (format s "No Objective-C class named ~S." (objc-error-name c)))))

(define-condition no-such-protocol (objc-error) ()
  (:report (lambda (c s)
             (format s "No Objective-C protocol named ~S." (objc-error-name c)))))

(define-condition class-definition-error (objc-error) ()
  (:report (lambda (c s)
             (format s "Could not create the Objective-C class ~S." (objc-error-name c)))))
