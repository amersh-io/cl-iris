;;;; ipc.lisp -- JavaScript and Lisp talking both ways.
;;;;
;;;;   qlot exec sbcl --load examples/ipc.lisp
;;;;
;;;; The page calls Lisp with iris.invoke, which returns a Promise of Lisp's
;;;; answer, and tells Lisp things with iris.post. Lisp updates the page every
;;;; second with EVAL-JS. JavaScript objects arrive as hash tables, arrays as
;;;; vectors.

(asdf:load-asd (merge-pathnames "../cl-iris.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-iris")

(defpackage #:cl-iris.examples.ipc
  (:use #:cl #:cl-iris)
  (:export #:main))

(in-package #:cl-iris.examples.ipc)

(defparameter *page* "<!doctype html>
<title>IPC</title>
<style>body { font: 15px -apple-system, sans-serif; margin: 2em; }</style>
<p>Lisp's clock: <b id=clock>...</b></p>
<p><input id=a value=2 size=4> + <input id=b value=40 size=4>
   <button id=add>Ask Lisp</button> = <b id=sum>?</b></p>
<p><button id=hello>Post a message to Lisp</button></p>
<script>
  document.getElementById('add').onclick = async () => {
    const answer = await iris.invoke({op: 'add',
                                      args: [Number(a.value), Number(b.value)]});
    document.getElementById('sum').textContent = answer;
  };
  document.getElementById('hello').onclick = () =>
    iris.post({event: 'hello', at: new Date().toISOString()});
</script>")

(defun answer (request)
  "Answer iris.invoke(REQUEST); an error here rejects the page's Promise."
  (let ((op (gethash "op" request)))
    (cond ((equal op "add") (reduce #'+ (gethash "args" request)))
          (t (error "Unknown operation ~S." op)))))

(defun hear (message)
  (format t "~&The page says: ~A at ~A~%"
          (gethash "event" message) (gethash "at" message)))

(defun launch ()
  (let* ((window (make-window :title "IPC" :width 520 :height 260 :center t))
         (webview (make-webview window :html *page* :on-invoke #'answer :on-message #'hear)))
    (run-every 1 (lambda ()
                   (multiple-value-bind (s m h) (get-decoded-time)
                     (eval-js webview
                              (format nil "document.getElementById('clock').textContent = '~2,'0D:~2,'0D:~2,'0D'"
                                      h m s)
                              :wait nil))))))

(defun main (&rest options)
  "Open the window and run until it is closed. OPTIONS go to RUN-APPLICATION."
  (apply #'run-application
         (append options (list :quit-on-last-window-closed t :on-launch #'launch))))

#-cl-iris-example-test (main)
