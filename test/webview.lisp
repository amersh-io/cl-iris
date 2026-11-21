;;;; Tests for cl-iris/webview, run on the worker thread like the window checks.

(in-package #:cl-iris/test)

(defparameter *index-html*
  "<!doctype html><title>iris</title>
<script>window.webkit.messageHandlers.iris.postMessage('ready:' + location.href)</script>")

(defun serve (url)
  (cond ((string= url "iris://app/index.html") *index-html*)
        ((string= url "iris://app/data.txt") (values "from lisp" "text/plain"))
        (t nil)))

(defvar *late-bound-messages* '())

(defun late-bound-handler (message)
  (push (list :first message) *late-bound-messages*))

(defun wait-until (predicate &key (timeout 10))
  "Poll PREDICATE until it returns true or TIMEOUT seconds pass."
  (loop repeat (* timeout 20)
        thereis (funcall predicate)
        do (sleep 0.05)))

(defun webview-checks ()
  (let* ((messages '())
         (lock (sb-thread:make-mutex))
         (window (make-window :title "cl-iris webview test" :width 640 :height 400
                              :activate nil))
         (webview nil))
    (flet ((received (message)
             (sb-thread:with-mutex (lock) (member message messages :test #'equal))))
      (setf webview
            (make-webview
             window
             :on-request #'serve
             :on-message (lambda (message)
                           (sb-thread:with-mutex (lock) (push message messages))
                           ;; JS -> Lisp -> JS: answer a ping from the main thread.
                           (when (and (stringp message) (eql 0 (search "ping:" message)))
                             (eval-js webview
                                      (format nil "window.reply = 'pong:~A'" (subseq message 5))
                                      :wait nil)))
             :url "iris://app/index.html"))
      (check "a page served from Lisp posts a message back"
             (wait-until (lambda () (received "ready:iris://app/index.html"))))
      (check "eval-js returns strings"
             (equal "iris" (eval-js webview "document.title")))
      (check "eval-js returns numbers"
             (eql 42 (eval-js webview "1 + 41")))
      (check "eval-js returns objects as hash tables"
             (let ((value (eval-js webview "({a: [1, true, null], b: 'x'})")))
               (and (equalp (vector 1 t :null) (gethash "a" value))
                    (equal "x" (gethash "b" value)))))
      (check "eval-js signals JavaScript errors"
             (handler-case (progn (eval-js webview "throw new Error('nope')") nil)
               (javascript-error () t)))
      (check "eval-js leaves no handles behind"
             (let ((before (handle-count)))
               (dotimes (i 5) (eval-js webview "1"))
               (wait-until (lambda () (= before (handle-count))))))
      (check "eval-js gives up after its timeout"
             (handler-case
                 (progn (eval-js webview "const t = Date.now(); while (Date.now() - t < 500) {}; 1"
                                 :timeout 0.1)
                        nil)
               (main-thread-timeout () t)))
      (check "eval-js works again after a timeout"
             (eql 2 (eval-js webview "1 + 1")))
      (check "eval-js refuses to wait on the main thread"
             (handler-case (progn (on-main (lambda () (eval-js webview "1"))) nil)
               (error (e) (search "main thread" (princ-to-string e)))))
      (check "a message from JavaScript is answered by eval-js"
             (progn
               (eval-js webview "window.webkit.messageHandlers.iris.postMessage('ping:7'); 0")
               (wait-until (lambda () (equal "pong:7" (eval-js webview "window.reply || ''"))))))
      (check "fetch reaches the Lisp scheme handler"
             (progn
               (eval-js webview "fetch('iris://app/data.txt').then(r => r.text()).then(t => window.webkit.messageHandlers.iris.postMessage(t)); 0")
               (wait-until (lambda () (received "from lisp")))))
      (check "unknown paths answer 404"
             (progn
               (eval-js webview "fetch('iris://app/missing').then(r => window.webkit.messageHandlers.iris.postMessage('status:' + r.status)); 0")
               (wait-until (lambda () (received "status:404")))))
      (check "a handler given as a symbol follows its redefinition"
             (let* ((other (make-webview window :on-message 'late-bound-handler)))
               (load-html other "<script>window.webkit.messageHandlers.iris.postMessage('one')</script>")
               (wait-until (lambda () *late-bound-messages*))
               (setf (fdefinition 'late-bound-handler)
                     (lambda (message) (push (list :second message) *late-bound-messages*)))
               (eval-js other "window.webkit.messageHandlers.iris.postMessage('two'); 0")
               (prog1 (wait-until (lambda () (equal '(:second "two") (first *late-bound-messages*))))
                 (destroy-webview other))))
      (destroy-webview webview)
      (close-window window))))
