;;;; Screens (monitors) and scale factors.

(in-package #:cl-iris/window)

(defun rect-list (rect)
  (list (rect-x rect) (rect-y rect) (rect-width rect) (rect-height rect)))

(defun describe-screen (screen)
  "A plist for SCREEN: :NAME, :FRAME and :VISIBLE-FRAME as (x y width
height) — the visible frame leaves out the menu bar and the Dock — and
:SCALE-FACTOR, 2 on a Retina display. Main thread."
  (list :name (lisp-string (send screen "localizedName"))
        :frame (rect-list (send screen "frame" (:struct ns-rect)))
        :visible-frame (rect-list (send screen "visibleFrame" (:struct ns-rect)))
        :scale-factor (send screen "backingScaleFactor" :double)))

(defun screens ()
  "Every screen, the one with the menu bar first, as plists (see DESCRIBE-SCREEN)."
  (on-main
   (lambda ()
     (let ((array (send (find-class* "NSScreen") "screens")))
       (loop for i below (send array "count" :unsigned-long)
             collect (describe-screen (send array "objectAtIndex:" :unsigned-long i)))))))

(defun main-screen ()
  "The screen with the window that has keyboard focus, or the first screen."
  (on-main (lambda () (describe-screen (send (find-class* "NSScreen") "mainScreen")))))

(defun window-screen (window)
  "The screen WINDOW is mostly on, as a plist, or NIL when it is off screen."
  (on-main
   (lambda ()
     (let ((screen (send window "screen")))
       (unless (cffi:null-pointer-p screen)
         (describe-screen screen))))))

(defun window-scale-factor (window)
  "How many pixels WINDOW draws per point: 2 on a Retina display."
  (on-main (lambda () (send window "backingScaleFactor" :double))))
