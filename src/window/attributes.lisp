;;;; Reading and changing a window's attributes.
;;;;
;;;; Positions and sizes are in points, in the screen's coordinates: the
;;;; origin is the bottom-left corner of the main screen and Y grows upwards,
;;;; as everywhere in AppKit.

(in-package #:cl-iris/window)

(defun (setf window-title) (title window)
  (on-main (lambda () (send window "setTitle:" :pointer (ns-string title) :void)))
  title)

(defun resize-window (window width height)
  "Make WINDOW's content area WIDTH by HEIGHT points, keeping its bottom-left
corner in place."
  (on-main
   (lambda ()
     (send window "setContentSize:" (:struct ns-size) (make-size width height) :void)))
  nil)
