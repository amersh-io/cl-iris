;;;; multi-window.lisp -- several windows, their events, and two webviews in one.
;;;;
;;;;   qlot exec sbcl --load examples/multi-window.lisp
;;;;
;;;; One window holds two webviews side by side, placed with :BOUNDS, that
;;;; talk to each other through Lisp. A second window logs every window
;;;; event, and asks before it lets itself be closed.

(asdf:load-asd (merge-pathnames "../cl-iris.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-iris")

(defpackage #:cl-iris.examples.multi-window
  (:use #:cl #:cl-iris)
  (:export #:main))

(in-package #:cl-iris.examples.multi-window)

(defvar *left* nil)
(defvar *right* nil)
(defvar *log* nil)
(defvar *close-asked* nil)

(defun pane (name)
  (format nil "<!doctype html><title>~A</title>
<style>body { font: 14px -apple-system, sans-serif; margin: 1em; }</style>
<h3>~A</h3>
<button onclick=\"iris.post('ping from ~A')\">Ping the other side</button>
<ul id=got></ul>
<script>
  window.receive = (text) => {
    const li = document.createElement('li');
    li.textContent = text;
    got.appendChild(li);
  };
</script>" name name name))

(defun deliver (to text)
  (eval-js to (format nil "receive(~S)" text) :wait nil))

(defun log-event (window event &rest arguments)
  (when *log*
    (deliver *log* (format nil "~A ~(~A~)~{ ~A~}" (window-title window) event arguments))))

(defun launch ()
  (let ((panes (make-window :title "Two webviews" :width 640 :height 300 :x 120 :y 420
                            :on-event #'log-event)))
    (setf *left* (make-webview panes :bounds '(0 0 320 300) :html (pane "Left")
                                     :on-message (lambda (text) (deliver *right* text)))
          *right* (make-webview panes :bounds '(320 0 320 300) :html (pane "Right")
                                      :on-message (lambda (text) (deliver *left* text)))))
  (let ((events (make-window :title "Events" :width 420 :height 300 :x 780 :y 420
                             :on-event #'log-event
                             ;; Returning false keeps the window open.
                             :on-close-request (lambda (window)
                                                 (declare (ignore window))
                                                 (deliver *log* "Close once more to really close.")
                                                 (shiftf *close-asked* t)))))
    (setf *log* (make-webview events :html (pane "Events")))))

(defun main (&rest options)
  "Open the windows and run until both are closed. OPTIONS go to RUN-APPLICATION."
  (apply #'run-application
         (append options (list :quit-on-last-window-closed t :on-launch #'launch))))

#-cl-iris-example-test (main)
