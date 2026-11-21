;;;; Loading the Objective-C runtime and the C entry points cl-iris uses.

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
