;;;; hello.lisp -- a window with a page in it.
;;;;
;;;;   qlot exec sbcl --load examples/hello.lisp
;;;;
;;;; Closing the window quits.

(asdf:load-asd (merge-pathnames "../cl-iris.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-iris")

(defpackage #:cl-iris.examples.hello
  (:use #:cl #:cl-iris)
  (:export #:main))

(in-package #:cl-iris.examples.hello)

(defparameter *page* "<!doctype html>
<title>Hello from cl-iris</title>
<style>
  body { font: 16px -apple-system, sans-serif; display: grid; place-items: center;
         height: 100vh; margin: 0; }
</style>
<h1>Hello from Lisp</h1>")

(defun launch ()
  (let ((window (make-window :title "Hello" :width 480 :height 320 :center t)))
    (make-webview window :html *page*)))

(defun main (&rest options)
  "Open the window and run until it is closed. OPTIONS go to RUN-APPLICATION."
  (apply #'run-application
         (append options (list :quit-on-last-window-closed t :on-launch #'launch))))

#-cl-iris-example-test (main)
