;;;; Lisp objects that stand for Objective-C objects.
;;;;
;;;; Higher layers hand out CLOS objects (a window, a webview) rather than bare
;;;; foreign pointers, so they print, can be described and dispatched on. The
;;;; Objective-C object behind one stays reachable: SEND accepts such an object
;;;; wherever it accepts a pointer.

(in-package #:cl-iris/objc)

(defgeneric objc-object-pointer (object)
  (:documentation "The Objective-C object (an id) the OBJC-OBJECT OBJECT stands for."))

(defclass objc-object ()
  ((pointer :initarg :pointer
            :reader objc-object-pointer
            :documentation "The Objective-C object (an id) this Lisp object stands for."))
  (:documentation "A Lisp object standing for an Objective-C object. SEND takes
one as its receiver and as any :POINTER argument, in place of the pointer."))

(defmethod print-object ((object objc-object) stream)
  (print-unreadable-object (object stream :type t)
    (format stream "#x~X" (cffi:pointer-address (objc-object-pointer object)))))

(declaim (inline objc-pointer))
(defun objc-pointer (object)
  "The foreign pointer for OBJECT: OBJECT itself when it is a pointer, the
pointer an OBJC-OBJECT stands for otherwise."
  (if (cffi:pointerp object)
      object
      (objc-object-pointer object)))

(defun objc-address (object)
  "The address of the Objective-C object OBJECT is or stands for. Objective-C
objects never move, so it is a stable key for the object's lifetime."
  (cffi:pointer-address (objc-pointer object)))
