;;;; Defining classes at run time.

(in-package #:cl-iris/objc)

;;; Defining classes at run time

(defun ensure-class (name superclass)
  "Return the class NAME, creating and registering it as a subclass of
SUPERCLASS (a class name) when it does not exist yet."
  (or (find-class* name nil)
      (let ((class (%allocate-class-pair (find-class* superclass) name 0)))
        (when (cffi:null-pointer-p class)
          (error 'class-definition-error :name name))
        (%register-class-pair class)
        class)))

(defun set-method (class selector imp types)
  "Install IMP (a CFFI callback pointer) as the implementation of SELECTOR on
CLASS, replacing any implementation it already has. TYPES is the Objective-C
type encoding of the method, e.g. \"q@:qq\".

IMP receives the receiver and the selector before the method's own arguments."
  (%replace-method class (selector selector) imp types)
  class)

(defun add-protocol (class name &key (errorp t))
  "Declare that CLASS conforms to the protocol NAME. Adding it twice is harmless.

Some framework protocols are only declared in headers and never registered
with the runtime (WebKit's WKScriptMessageHandler, for one); for those, pass
ERRORP NIL to carry on without the declaration. Returns CLASS, or NIL when
the protocol was not found."
  (let ((protocol (%get-protocol name)))
    (cond ((not (cffi:null-pointer-p protocol))
           (%add-protocol class protocol)
           class)
          (errorp (error 'no-such-protocol :name name))
          (t nil))))
