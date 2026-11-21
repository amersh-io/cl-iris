;;;; Windows.

(in-package #:cl-iris/window)

;;; Windows

(defconstant +backing-store-buffered+ 2)

(defun make-window (&key (title "") (x 200) (y 200) (width 800) (height 600)
                      (style *default-style*) (activate t))
  "Open a window whose content area is WIDTH by HEIGHT points, with its
bottom-left corner at X, Y on the screen, and return it. STYLE is a list of
keywords as for WINDOW-STYLE; the default has a title bar with all three
buttons and can be resized, and NIL makes a borderless window. With
ACTIVATE, the application is brought to the front; without it, the window
opens without taking focus from other applications."
  (let ((window
          (on-main
           (lambda ()
             (let ((window (send (send (find-class* "NSWindow") "alloc")
                                 "initWithContentRect:styleMask:backing:defer:"
                                 (:struct ns-rect) (make-rect x y width height)
                                 :unsigned-long (style-mask style)
                                 :unsigned-long +backing-store-buffered+
                                 ;; BOOL as a byte: once a struct is passed by
                                 ;; value the call goes through libffi, which
                                 ;; rejects :BOOL.
                                 :unsigned-char 0)))
               ;; We release the window ourselves in CLOSE-WINDOW.
               (send window "setReleasedWhenClosed:" :bool nil :void)
               (send window "setTitle:" :pointer (ns-string title) :void)
               (send window "makeKeyAndOrderFront:" :pointer (cffi:null-pointer) :void)
               window)))))
    (when activate
      (activate-application))
    window))

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
