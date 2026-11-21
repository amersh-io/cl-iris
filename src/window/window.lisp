;;;; Windows.

(in-package #:cl-iris/window)

;;; Windows

(defconstant +backing-store-buffered+ 2)

(defun make-window (&key (title "") (x 200) (y 200) (width 800) (height 600)
                      (style *default-style*) (resizable t) (decorations t)
                      center min-size max-size level alpha background-color
                      transparent appearance (title-visible t) titlebar-transparent
                      (visible t) (activate t))
  "Open a window whose content area is WIDTH by HEIGHT points, with its
bottom-left corner at X, Y on the screen (or CENTER-ed), and return it.

STYLE is a list of keywords as for WINDOW-STYLE; the default has a title bar
with all three buttons and can be resized, and NIL makes a borderless
window. RESIZABLE NIL and DECORATIONS NIL take :RESIZABLE and :TITLED out of
it. MIN-SIZE and MAX-SIZE are lists (width height). LEVEL, ALPHA,
BACKGROUND-COLOR, TRANSPARENT, APPEARANCE, TITLE-VISIBLE and
TITLEBAR-TRANSPARENT set what the WINDOW- accessors of the same names set.

A VISIBLE window is shown at once; otherwise it waits for SHOW-WINDOW. With
ACTIVATE, the application is brought to the front; without it, the window
opens without taking focus from other applications."
  (let* ((style (remove-if (lambda (keyword)
                            (or (and (eq keyword :resizable) (not resizable))
                                (and (eq keyword :titled) (not decorations))))
                          style))
         (mask (style-mask style)))
    (when background-color (color-components background-color))
    (let ((window
            (on-main
             (lambda ()
               (let ((window (send (send (find-class* "NSWindow") "alloc")
                                   "initWithContentRect:styleMask:backing:defer:"
                                   (:struct ns-rect) (make-rect x y width height)
                                   :unsigned-long mask
                                   :unsigned-long +backing-store-buffered+
                                   ;; BOOL as a byte: once a struct is passed by
                                   ;; value the call goes through libffi, which
                                   ;; rejects :BOOL.
                                   :unsigned-char 0)))
                 ;; We release the window ourselves in CLOSE-WINDOW.
                 (send window "setReleasedWhenClosed:" :bool nil :void)
                 (send window "setTitle:" :pointer (ns-string title) :void)
                 ;; On the main thread, so these setters run in place, before
                 ;; the window is first drawn.
                 (when min-size (apply #'set-window-min-size window min-size))
                 (when max-size (apply #'set-window-max-size window max-size))
                 (when level (setf (window-level window) level))
                 (when alpha (setf (window-alpha window) alpha))
                 (when transparent (setf (window-transparent-p window) t))
                 (when background-color (setf (window-background-color window) background-color))
                 (when appearance (setf (window-appearance window) appearance))
                 (unless title-visible (setf (window-title-visible-p window) nil))
                 (when titlebar-transparent (setf (window-titlebar-transparent-p window) t))
                 (when center (send window "center" :void))
                 (when visible
                   (send window "makeKeyAndOrderFront:" :pointer (cffi:null-pointer) :void))
                 window)))))
      (when (and visible activate)
        (activate-application))
      window)))

(defun close-window (window)
  "Close WINDOW and release it."
  (on-main
   (lambda ()
     (send window "close" :void)
     (release window)))
  nil)

(defun window-number (window)
  "The window server's number for WINDOW, as used by screencapture -l."
  (on-main (lambda () (send window "windowNumber" :long))))

(defun window-title (window)
  (on-main (lambda () (lisp-string (send window "title")))))

(defun window-content-size (window)
  "Return the width and height of WINDOW's content area, in points."
  (on-main
   (lambda ()
     (let ((frame (send (send window "contentView") "frame" (:struct ns-rect))))
       (values (rect-width frame) (rect-height frame))))))
