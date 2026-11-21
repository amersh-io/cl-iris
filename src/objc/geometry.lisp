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

(cffi:defcstruct ns-size
  (width :double)
  (height :double))

(cffi:defcstruct ns-rect
  (x :double)
  (y :double)
  (width :double)
  (height :double))

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

(defun point-x (value) (getf value 'x))
(defun point-y (value) (getf value 'y))
(defun size-width (value) (getf value 'width))
(defun size-height (value) (getf value 'height))
(defun rect-x (value) (getf value 'x))
(defun rect-y (value) (getf value 'y))
(defun rect-width (value) (getf value 'width))
(defun rect-height (value) (getf value 'height))
