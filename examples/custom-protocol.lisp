;;;; custom-protocol.lisp -- a small site served by Lisp under app://.
;;;;
;;;;   qlot exec sbcl --load examples/custom-protocol.lisp
;;;;
;;;; Pages, an API endpoint that reads the request's method and body, and an
;;;; endpoint answered later from another thread. Nothing listens on a port:
;;;; WebKit hands every app:// request to Lisp.

(asdf:load-asd (merge-pathnames "../cl-iris.asd" (or *load-truename* *default-pathname-defaults*)))
(asdf:load-system "cl-iris")

(defpackage #:cl-iris.examples.custom-protocol
  (:use #:cl #:cl-iris)
  (:export #:main))

(in-package #:cl-iris.examples.custom-protocol)

(defparameter *files*
  '(("/index.html" "text/html" "<!doctype html>
<title>Served by Lisp</title>
<link rel=stylesheet href=/style.css>
<h1>Served by Lisp</h1>
<p><button id=echo>POST to /api/echo</button> <code id=echoed></code></p>
<p><button id=slow>GET /api/slow</button> <code id=slowed></code></p>
<script>
  echo.onclick = async () => {
    const r = await fetch('/api/echo', {method: 'POST', body: 'hello, Lisp'});
    echoed.textContent = r.status + ' ' + await r.text();
  };
  slow.onclick = async () => {
    slowed.textContent = 'waiting...';
    const r = await fetch('/api/slow');
    slowed.textContent = await r.text();
  };
</script>")
    ("/style.css" "text/css" "body { font: 15px -apple-system, sans-serif; margin: 2em; }
code { color: #a33; }")))

(defun path-of (url)
  "The path of an app://site/... URL."
  (let ((start (search "/" url :start2 (+ 3 (search "://" url)))))
    (if start (subseq url start) "/")))

(defun serve (request)
  "The body, content type and status for REQUEST."
  (let ((path (path-of (request-url request))))
    (cond ((string= path "/api/echo")
           (values (format nil "~A ~A"
                           (request-method request)
                           (sb-ext:octets-to-string (or (request-body request) #())
                                                    :external-format :utf-8))
                   "text/plain"))
          (t
           (let ((file (assoc (if (string= path "/") "/index.html" path) *files*
                              :test #'string=)))
             (if file
                 (values (third file) (second file))
                 (values "Not here." "text/plain" 404)))))))

(defun handle (request responder)
  "The app:// scheme is asynchronous: most requests are answered at once,
/api/slow a second later from another thread. RESPOND works from any thread."
  (if (string= "/api/slow" (path-of (request-url request)))
      (sb-thread:make-thread
       (lambda ()
         (sleep 1)
         (respond responder "answered a second later" :content-type "text/plain")))
      (multiple-value-bind (body content-type status) (serve request)
        (respond responder body :content-type content-type :status status))))

(defun launch ()
  (let ((window (make-window :title "Custom protocol" :width 560 :height 300 :center t)))
    (make-webview window
                  :protocols '(("app" handle :async t))
                  :url "app://site/index.html")))

(defun main (&rest options)
  "Open the window and run until it is closed. OPTIONS go to RUN-APPLICATION."
  (apply #'run-application
         (append options (list :quit-on-last-window-closed t :on-launch #'launch))))

#-cl-iris-example-test (main)
