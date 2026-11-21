;;;; Tests for cl-iris/webview, run on the worker thread like the window checks.

(in-package #:cl-iris/test)

(defparameter *index-html*
  "<!doctype html><title>iris</title>
<script>window.webkit.messageHandlers.iris.postMessage('ready:' + location.href)</script>")

(defvar *last-request* nil)

(defun serve (request)
  (let ((url (request-url request)))
    (setf *last-request* request)
    (cond ((string= url "iris://app/index.html") *index-html*)
          ((string= url "iris://app/data.txt") (values "from lisp" "text/plain"))
          ((string= url "iris://app/echo")
           (values (request-body request) "application/octet-stream" 201
                   (list (cons "X-Echo-Method" (request-method request))
                         (cons "X-Echo-Header" (or (request-header request "x-test") "")))))
          (t nil))))

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
      (check "a request carries its method, headers and body"
             (progn
               (eval-js webview "fetch('iris://app/echo', {method: 'POST', headers: {'X-Test': 'yes'}, body: 'payload'}).then(async r => window.webkit.messageHandlers.iris.postMessage(['echo', r.status, r.headers.get('X-Echo-Method'), r.headers.get('X-Echo-Header'), await r.text()].join('|'))); 0")
               (wait-until (lambda () (received "echo|201|POST|yes|payload")))))
      (check "request headers are an alist"
             (equal "yes" (request-header *last-request* "X-TEST")))
      (check "one webview answers several schemes"
             (let ((other (make-webview window
                                        :protocols (list (list "alpha" (lambda (r) (declare (ignore r)) "<title>a</title>"))
                                                         (list "Beta" (lambda (r) (declare (ignore r)) "<title>b</title>"))))))
               (prog1 (and (progn (load-url other "alpha://x/")
                                  (wait-until (lambda () (equal "a" (eval-js other "document.title")))))
                           (progn (load-url other "beta://x/")
                                  (wait-until (lambda () (equal "b" (eval-js other "document.title"))))))
                 (destroy-webview other))))
      (check "an asynchronous handler answers later from another thread"
             (let ((other (make-webview
                           window
                           :protocols
                           (list (list "later"
                                       (lambda (request responder)
                                         (sb-thread:make-thread
                                          (lambda ()
                                            (sleep 0.2)
                                            (respond responder
                                                     (format nil "<title>~A</title>"
                                                             (request-url request))))))
                                       :async t)))))
               (load-url other "later://x/")
               (prog1 (wait-until (lambda () (equal "later://x/" (eval-js other "document.title"))))
                 (destroy-webview other))))
      (check "an answer to a stopped request is dropped, not sent"
             (let* ((pending nil)
                    (other (make-webview
                            window
                            :protocols (list (list "never"
                                                   (lambda (request responder)
                                                     (declare (ignore request))
                                                     (setf pending responder))
                                                   :async t)))))
               (load-html other "<title>host</title>" :base-url "never://host/")
               (wait-until (lambda () (equal "host" (eval-js other "document.title"))))
               (eval-js other "window.ctl = new AbortController(); fetch('never://host/slow', {signal: ctl.signal}).catch(() => {}); 0")
               (and (wait-until (lambda () pending))
                    (responder-open-p pending)
                    (progn (eval-js other "ctl.abort(); 0")
                           (wait-until (lambda () (not (responder-open-p pending)))))
                    (progn (respond pending "too late")
                           ;; Still alive: the dropped answer never reached WebKit.
                           (prog1 (eql 3 (eval-js other "1 + 2"))
                             (destroy-webview other))))))
      (check "a webview can start from a string of HTML"
             (let ((other (make-webview window :html "<title>inline</title>"
                                               :base-url "https://example.invalid/")))
               (prog1 (and (wait-until (lambda () (equal "inline" (eval-js other "document.title"))))
                           (equal "https://example.invalid/" (eval-js other "location.href")))
                 (destroy-webview other))))
      (check "a webview's first request carries the headers it was given"
             (let ((other (make-webview window :on-request #'serve :url "iris://app/data.txt"
                                               :headers '(("X-Test" . "first")))))
               (prog1 (wait-until (lambda ()
                                    (and *last-request*
                                         (equal "first" (request-header *last-request* "X-Test")))))
                 (destroy-webview other))))
      (check "load-url sends extra headers"
             (progn
               (load-url webview "iris://app/data.txt" :headers '(("X-Test" . "again")))
               (wait-until (lambda () (equal "again" (request-header *last-request* "X-Test"))))))
      (check "load-url refuses what is not a URL"
             (handler-case (progn (load-url webview "not a url") nil)
               (error (e) (search "absolute URL" (princ-to-string e)))))
      (check "a scheme WebKit handles itself is refused before WebKit sees it"
             (handler-case (progn (make-webview window :protocols (list (list "https" #'serve))) nil)
               (error (e) (search "itself" (princ-to-string e)))))
      (check "a scheme given twice is refused"
             (handler-case (progn (make-webview window :protocols (list (list "dup" #'serve)
                                                                        (list "DUP" #'serve)))
                                  nil)
               (error (e) (search "twice" (princ-to-string e)))))
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
