;;;; Loading AppKit; the geometry structs passed by value.

(in-package #:cl-iris/window)

(cffi:define-foreign-library appkit
  (:darwin "/System/Library/Frameworks/AppKit.framework/AppKit"))

(cffi:use-foreign-library appkit)

;;; NSRect and NSPoint are passed by value, which needs cffi-libffi. The flat
;;; layouts below have the same size and alignment as the nested Cocoa ones.

(cffi:defcstruct ns-point
  (x :double)
  (y :double))

(cffi:defcstruct ns-rect
  (x :double)
  (y :double)
  (width :double)
  (height :double))

(defun rect (x y width height)
  (list 'x (float x 1d0) 'y (float y 1d0)
        'width (float width 1d0) 'height (float height 1d0)))
