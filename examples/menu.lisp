;;;; menu.lisp -- a menu bar with items that call Lisp.
;;;;
;;;;   qlot exec sbcl --load examples/menu.lisp
;;;;
;;;; The menu bar is a list. DEFAULT-MENU-BAR gives the one every Mac
;;;; application has (its Edit menu is what makes Cmd+C and Cmd+V work in a
;;;; webview); this example adds a menu of its own after it.

(asdf:load-asd (merge-pathnames "../cl-iris.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-iris")

(defpackage #:cl-iris.examples.menu
  (:use #:cl #:cl-iris)
  (:export #:main))

(in-package #:cl-iris.examples.menu)

(defvar *webview* nil)

(defun say (text)
  (eval-js *webview*
           (format nil "document.getElementById('said').textContent = ~S" text)
           :wait nil))

(defun toggle-dark ()
  "Flip the menu item's check mark and the window's appearance with it."
  (let* ((item (find-menu-item "Lisp" "Dark Appearance"))
         (dark (not (menu-item-checked-p item))))
    (setf (menu-item-checked-p item) dark
          (window-appearance (webview-window *webview*)) (if dark :dark :light))
    (say (if dark "Dark it is." "Light again."))))

(defun menu-bar ()
  (append (default-menu-bar)
          `((:menu "Lisp"
             (:item "Say Hello" :key "1" :action ,(lambda () (say "Hello from the menu.")))
             (:item "Say the Time" :key "2"
                    :action ,(lambda ()
                               (multiple-value-bind (s m h) (get-decoded-time)
                                 (say (format nil "It is ~2,'0D:~2,'0D:~2,'0D." h m s)))))
             :separator
             (:item "Dark Appearance" :key "d" :modifiers (:command :shift)
                    :action toggle-dark)
             (:menu "More"
              (:item "Not Yet" :enabled nil))))))

(defun launch ()
  (let ((window (make-window :title "Menu" :width 420 :height 220 :center t)))
    (setf *webview*
          (make-webview window :html "<!doctype html><title>Menu</title>
<style>body { font: 15px -apple-system, sans-serif; margin: 2em; }
@media (prefers-color-scheme: dark) { body { background: #222; color: #eee; } }</style>
<p>Try the <b>Lisp</b> menu, or Cmd+1 and Cmd+2.</p>
<p id=said></p>"))))

(defun main (&rest options)
  "Open the window and run until it is closed. OPTIONS go to RUN-APPLICATION."
  (apply #'run-application
         (append options (list :quit-on-last-window-closed t
                               :menu-bar (menu-bar)
                               :on-launch #'launch))))

#-cl-iris-example-test (main)
