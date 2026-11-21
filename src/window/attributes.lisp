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

(defun window-frame (window)
  "Return the X, Y, width and height of WINDOW's whole frame, title bar
included."
  (on-main
   (lambda ()
     (let ((frame (send window "frame" (:struct ns-rect))))
       (values (rect-x frame) (rect-y frame) (rect-width frame) (rect-height frame))))))

(defun window-position (window)
  "Return the X and Y of WINDOW's bottom-left corner."
  (multiple-value-bind (x y) (window-frame window)
    (values x y)))

(defun move-window (window x y)
  "Put WINDOW's bottom-left corner at X, Y."
  (on-main
   (lambda ()
     (send window "setFrameOrigin:" (:struct ns-point) (make-point x y) :void)))
  nil)

(defun center-window (window)
  "Put WINDOW in the middle of its screen, a little above center as macOS
places new windows."
  (on-main (lambda () (send window "center" :void)))
  nil)

(defun size-values (size)
  (values (size-width size) (size-height size)))

(defun window-min-size (window)
  "Return the smallest width and height the user can resize WINDOW's content
area to."
  (on-main (lambda () (size-values (send window "contentMinSize" (:struct ns-size))))))

(defun set-window-min-size (window width height)
  "Keep the user from resizing WINDOW's content area below WIDTH by HEIGHT."
  (on-main
   (lambda ()
     (send window "setContentMinSize:" (:struct ns-size) (make-size width height) :void)))
  nil)

(defun window-max-size (window)
  "Return the largest width and height the user can resize WINDOW's content
area to."
  (on-main (lambda () (size-values (send window "contentMaxSize" (:struct ns-size))))))

(defun set-window-max-size (window width height)
  "Keep the user from resizing WINDOW's content area beyond WIDTH by HEIGHT."
  (on-main
   (lambda ()
     (send window "setContentMaxSize:" (:struct ns-size) (make-size width height) :void)))
  nil)
