;;;; cl-iris/objc -- a thin CFFI binding to the Objective-C runtime.
;;;;
;;;; Classes and selectors are looked up by name on every use instead of being
;;;; cached as pointers, so an image saved with SAVE-LISP-AND-DIE never carries
;;;; addresses from the process that built it.

(defpackage #:cl-iris/objc
  (:use #:cl)
  (:export #:find-class*
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

(in-package #:cl-iris/objc)

(cffi:define-foreign-library libobjc
  (:darwin "/usr/lib/libobjc.A.dylib"))

(cffi:define-foreign-library foundation
  (:darwin "/System/Library/Frameworks/Foundation.framework/Foundation"))

(cffi:use-foreign-library libobjc)
(cffi:use-foreign-library foundation)

;;; Runtime entry points

(cffi:defcfun ("objc_getClass" %get-class) :pointer
  (name :string))

(cffi:defcfun ("sel_registerName" %register-name) :pointer
  (name :string))

(cffi:defcfun ("objc_allocateClassPair" %allocate-class-pair) :pointer
  (superclass :pointer) (name :string) (extra-bytes :size))

(cffi:defcfun ("objc_registerClassPair" %register-class-pair) :void
  (class :pointer))

(cffi:defcfun ("class_replaceMethod" %replace-method) :pointer
  (class :pointer) (selector :pointer) (imp :pointer) (types :string))

(cffi:defcfun ("objc_getProtocol" %get-protocol) :pointer
  (name :string))

(cffi:defcfun ("class_addProtocol" %add-protocol) :bool
  (class :pointer) (protocol :pointer))

(cffi:defcfun ("objc_autoreleasePoolPush" %pool-push) :pointer)

(cffi:defcfun ("objc_autoreleasePoolPop" %pool-pop) :void
  (pool :pointer))

;;; Classes and selectors

(defun find-class* (name &optional (errorp t))
  "Return the Objective-C class named NAME, or signal an error if there is none
and ERRORP is true (otherwise return NIL)."
  (let ((class (%get-class name)))
    (cond ((not (cffi:null-pointer-p class)) class)
          (errorp (error "No Objective-C class named ~S." name))
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

;;; Strings

(defun ns-string (string)
  "Return an autoreleased NSString holding the Lisp STRING."
  (send (find-class* "NSString") "stringWithUTF8String:"
        :string string))

(defun lisp-string (ns-string)
  "Return the contents of NS-STRING as a Lisp string."
  (cffi:foreign-string-to-lisp (send ns-string "UTF8String")
                               :encoding :utf-8))

;;; Autorelease pools

(defmacro with-autorelease-pool (&body body)
  "Run BODY inside a fresh autorelease pool, draining it on exit."
  (let ((pool (gensym "POOL")))
    `(let ((,pool (%pool-push)))
       (unwind-protect (progn ,@body)
         (%pool-pop ,pool)))))

;;; Defining classes at run time

(defun ensure-class (name superclass)
  "Return the class NAME, creating and registering it as a subclass of
SUPERCLASS (a class name) when it does not exist yet."
  (or (find-class* name nil)
      (let ((class (%allocate-class-pair (find-class* superclass) name 0)))
        (when (cffi:null-pointer-p class)
          (error "Could not allocate Objective-C class ~S." name))
        (%register-class-pair class)
        class)))

(defun set-method (class selector imp types)
  "Install IMP (a CFFI callback pointer) as the implementation of SELECTOR on
CLASS, replacing any implementation it already has. TYPES is the Objective-C
type encoding of the method, e.g. \"q@:qq\".

IMP receives the receiver and the selector before the method's own arguments."
  (%replace-method class (selector selector) imp types)
  class)

(defun add-protocol (class name)
  "Declare that CLASS conforms to the protocol NAME. Adding it twice is harmless."
  (let ((protocol (%get-protocol name)))
    (when (cffi:null-pointer-p protocol)
      (error "No Objective-C protocol named ~S." name))
    (%add-protocol class protocol)
    class))
