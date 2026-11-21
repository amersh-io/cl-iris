;;;; Floating point traps around Cocoa.

(in-package #:cl-iris/window)

;;; Floating point traps
;;;
;;; SBCL enables FP traps that Cocoa does not expect; AppKit and WebKit would
;;; otherwise raise FLOATING-POINT-INVALID-OPERATION and friends inside Lisp.

(defmacro with-cocoa-float-traps (&body body)
  "Run BODY with the floating point traps Cocoa relies on being masked."
  `(sb-int:with-float-traps-masked
       (:overflow :invalid :divide-by-zero :inexact :underflow)
     ,@body))
