;;;; NSPoint, NSSize and NSRect, which Cocoa passes by value.
;;;;
;;;; Passing a struct by value goes through cffi-libffi. CFFI hands such a
;;;; struct to Lisp as a plist; the constructors and readers below hide that.
;;;; The flat NS-RECT has the same size, alignment and calling convention as
;;;; Cocoa's nested {origin, size}.

(in-package #:cl-iris/objc)

(cffi:defcstruct ns-point
  (x :double)
  (y :double))

(setf (documentation 'ns-point 'type)
      "Cocoa's NSPoint, for (:STRUCT NS-POINT) in SEND; make one with MAKE-POINT.")

(cffi:defcstruct ns-size
  (width :double)
  (height :double))

(setf (documentation 'ns-size 'type)
      "Cocoa's NSSize, for (:STRUCT NS-SIZE) in SEND; make one with MAKE-SIZE.")

(cffi:defcstruct ns-rect
  (x :double)
  (y :double)
  (width :double)
  (height :double))

(setf (documentation 'ns-rect 'type)
      "Cocoa's NSRect, for (:STRUCT NS-RECT) in SEND; make one with MAKE-RECT.")

(defun make-point (x y)
  "A value for a (:STRUCT NS-POINT) argument."
  (list 'x (float x 1d0) 'y (float y 1d0)))

(defun make-size (width height)
  "A value for a (:STRUCT NS-SIZE) argument."
  (list 'width (float width 1d0) 'height (float height 1d0)))

(defun make-rect (x y width height)
  "A value for a (:STRUCT NS-RECT) argument; X, Y is the bottom-left corner."
  (list 'x (float x 1d0) 'y (float y 1d0)
        'width (float width 1d0) 'height (float height 1d0)))

(defun point-x (value)
  "The X of an NS-POINT VALUE returned by SEND."
  (getf value 'x))

(defun point-y (value)
  "The Y of an NS-POINT VALUE returned by SEND."
  (getf value 'y))

(defun size-width (value)
  "The width of an NS-SIZE VALUE returned by SEND."
  (getf value 'width))

(defun size-height (value)
  "The height of an NS-SIZE VALUE returned by SEND."
  (getf value 'height))

(defun rect-x (value)
  "The X of the bottom-left corner of an NS-RECT VALUE returned by SEND."
  (getf value 'x))

(defun rect-y (value)
  "The Y of the bottom-left corner of an NS-RECT VALUE returned by SEND."
  (getf value 'y))

(defun rect-width (value)
  "The width of an NS-RECT VALUE returned by SEND."
  (getf value 'width))

(defun rect-height (value)
  "The height of an NS-RECT VALUE returned by SEND."
  (getf value 'height))
