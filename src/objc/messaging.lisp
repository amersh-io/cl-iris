;;;; Classes, selectors and objc_msgSend.

(in-package #:cl-iris/objc)

;;; Classes and selectors

(defun find-class* (name &optional (errorp t))
  "Return the Objective-C class named NAME, or signal NO-SUCH-CLASS if there is
none and ERRORP is true (otherwise return NIL)."
  (let ((class (%get-class name)))
    (cond ((not (cffi:null-pointer-p class)) class)
          (errorp (error 'no-such-class :name name))
          (t nil))))

(defun selector (name)
  "Return the selector (SEL) for NAME. A pointer is returned unchanged."
  (if (stringp name) (%register-name name) name))

;;; Messaging

(defmacro send (receiver selector &rest args)
  "Send SELECTOR to RECEIVER through objc_msgSend.

ARGS are CFFI type/value pairs as in CFFI:FOREIGN-FUNCALL, optionally followed
by the return type, which defaults to :POINTER. RECEIVER may be an object or a
class pointer; SELECTOR may be a string or a SEL.

objc_msgSend is called with exactly the signature given here, never as a
variadic function, which is what the arm64 calling convention requires."
  `(cffi:foreign-funcall "objc_msgSend"
                         :pointer ,receiver
                         :pointer (selector ,selector)
                         ,@args
                         ,@(when (evenp (length args)) '(:pointer))))

(defun responds-to-p (object selector)
  "True if OBJECT responds to SELECTOR."
  (send object "respondsToSelector:" :pointer (selector selector) :bool))

(defun kind-of-p (object class-name)
  "True if OBJECT is an instance of the class CLASS-NAME or of a subclass."
  (send object "isKindOfClass:" :pointer (find-class* class-name) :bool))

;;; Reference counting (manual: cl-iris does not use ARC)

(defun retain (object)
  "Add a reference to OBJECT and return it."
  (send object "retain"))

(defun release (object)
  "Drop a reference to OBJECT. Returns NIL."
  (send object "release" :void)
  nil)

(defun autorelease (object)
  "Drop a reference to OBJECT when the current autorelease pool drains.
Returns OBJECT."
  (send object "autorelease"))

(defun retain-count (object)
  "OBJECT's reference count, for tests and debugging only."
  (send object "retainCount" :unsigned-long))
