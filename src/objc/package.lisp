;;;; cl-iris/objc -- a thin CFFI binding to the Objective-C runtime.
;;;;
;;;; Classes and selectors are looked up by name on every use instead of being
;;;; cached as pointers, so an image saved with SAVE-LISP-AND-DIE never carries
;;;; addresses from the process that built it.

(defpackage #:cl-iris/objc
  (:use #:cl)
  (:export #:ns-point
           #:ns-size
           #:ns-rect
           #:make-point
           #:make-size
           #:make-rect
           #:point-x
           #:point-y
           #:size-width
           #:size-height
           #:rect-x
           #:rect-y
           #:rect-width
           #:rect-height
           #:objc-error
           #:objc-error-name
           #:no-such-class
           #:no-such-protocol
           #:class-definition-error
           #:find-class*
           #:selector
           #:send
           #:ns-string
           #:lisp-string
           #:with-autorelease-pool
           #:ensure-class
           #:set-method
           #:add-protocol
           #:responds-to-p
           #:kind-of-p))
