;;;; Sending a message to the superclass's implementation (objc_msgSendSuper),
;;;; for methods that override one and still want it.

(in-package #:cl-iris/objc)

(defmacro send-super (receiver class-name selector &rest args)
  "Like SEND, but run the implementation of SELECTOR that the superclass of
the class CLASS-NAME has, for RECEIVER -- an instance of CLASS-NAME or of a
subclass. Used inside a method CLASS-NAME overrides."
  (let ((super (gensym "SUPER")))
    `(cffi:with-foreign-object (,super :pointer 2)
       (setf (cffi:mem-aref ,super :pointer 0) (objc-pointer ,receiver)
             (cffi:mem-aref ,super :pointer 1)
             (cffi:foreign-funcall "class_getSuperclass"
                                   :pointer (find-class* ,class-name) :pointer))
       (cffi:foreign-funcall "objc_msgSendSuper"
                             :pointer ,super
                             :pointer (selector ,selector)
                             ,@(unwrap-pointer-arguments args)
                             ,@(when (evenp (length args)) '(:pointer))))))
