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

;;; A tiny HTTP proxy, to see a webview's traffic really go through one.

(eval-when (:compile-toplevel :load-toplevel :execute)
  (require :sb-bsd-sockets)
  (require :sb-posix))

(defvar *proxied-lines* '()
  "The request lines the test proxy saw, newest first.")

(defun read-head (stream)
  (loop for line = (string-right-trim '(#\Return) (read-line stream nil ""))
        until (string= line "") collect line))

(defun crlf-format (stream control &rest arguments)
  (write-string (substitute #\Return #\| (apply #'format nil control arguments)) stream)
  (finish-output stream))

(defun proxied-page (request-line)
  (declare (ignore request-line))
  (values "<title>proxied</title>" "text/html"))

(defun serve-http (client respond)
  "Answer one HTTP request on CLIENT -- through a CONNECT tunnel too -- with
the body and content type RESPOND returns for its request line."
  (let ((stream (sb-bsd-sockets:socket-make-stream
                 client :input t :output t :element-type 'character
                        :external-format :latin-1 :buffering :full)))
    (unwind-protect
         (ignore-errors
          (let ((line (first (read-head stream))))
            (push line *proxied-lines*)
            (when (eql 0 (search "CONNECT" line))
              (crlf-format stream "HTTP/1.1 200 Connection established|~%|~%")
              (setf line (first (read-head stream)))
              (push line *proxied-lines*))
            (multiple-value-bind (body content-type) (funcall respond line)
              (crlf-format stream "HTTP/1.1 200 OK|~%Content-Type: ~A|~%~
                                   Content-Length: ~D|~%Connection: close|~%|~%~A"
                           content-type (length body) body))))
      (ignore-errors (close stream)))))

(defun start-test-server (&optional (respond #'proxied-page))
  "Listen on a free local port, answering every request -- direct, or as a
proxy -- with what RESPOND returns for its request line; return the port."
  (let ((socket (make-instance 'sb-bsd-sockets:inet-socket :type :stream :protocol :tcp)))
    (sb-bsd-sockets:socket-bind socket #(127 0 0 1) 0)
    (sb-bsd-sockets:socket-listen socket 5)
    (sb-thread:make-thread
     (lambda ()
       (loop (serve-http (sb-bsd-sockets:socket-accept socket) respond)))
     :name "cl-iris test server")
    (nth-value 1 (sb-bsd-sockets:socket-name socket))))

(defun pdf-text (path)
  "The text of the PDF file at PATH, read with PDFKit, or NIL."
  (cffi:load-foreign-library "/System/Library/Frameworks/PDFKit.framework/PDFKit")
  (with-autorelease-pool
    (let ((document (send (send (find-class* "PDFDocument") "alloc") "initWithURL:"
                          :pointer (send (find-class* "NSURL") "fileURLWithPath:"
                                         :pointer (ns-string (namestring path))))))
      (unless (cffi:null-pointer-p document)
        (prog1 (let ((text (send document "string")))
                 (unless (cffi:null-pointer-p text) (lisp-string text)))
          (release document))))))

;;; A stand-in for the NSDraggingInfo AppKit passes while files are dragged:
;;; the real one only comes from a mouse. Its location, an NSPoint returned by
;;; value, cannot come from a Lisp callback, so the test redefines the Lisp
;;; function that reads it.

(defvar *test-drag-pasteboard* nil)

(define-objc-class "CLIrisTestDraggingInfo" ()
  (:method "draggingPasteboard" :pointer (self)
    *test-drag-pasteboard*))

(defun test-dragging-info (paths)
  (let ((pasteboard (send (find-class* "NSPasteboard") "pasteboardWithUniqueName")))
    (send pasteboard "clearContents" :long)
    (send pasteboard "writeObjects:"
          :pointer (cl-iris/webview::file-url-array paths) :bool)
    (setf *test-drag-pasteboard* pasteboard)
    (send (send (find-class* "CLIrisTestDraggingInfo") "alloc") "init")))

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
      (check "a completion handler released uncalled reports that it was dropped"
             (let ((outcome nil))
               (release-block (cl-iris/webview::make-completion-block
                               (lambda (value message) (setf outcome (list value message)))))
               (and (equal (list nil cl-iris/webview::*dropped-message*) outcome)
                    (let ((called nil) (dropped nil))
                      (let ((block (make-block (cffi:callback cl-iris/webview::js-completion)
                                               (lambda (&rest args) (declare (ignore args)) (setf called t))
                                               :on-drop (lambda () (setf dropped t)))))
                        (call-block block :pointer (cffi:null-pointer) :pointer (cffi:null-pointer))
                        (release-block block))
                      (and called (not dropped))))))
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
      (check "init scripts run before the page's own scripts"
             (let ((other (make-webview
                           window
                           :init-scripts '("window.injected = 41;")
                           :html "<script>document.title = 'seen ' + (window.injected + 1)</script>")))
               (prog1 (wait-until (lambda () (equal "seen 42" (eval-js other "document.title"))))
                 (destroy-webview other))))
      (check "a main-frame-only init script skips iframes"
             (let ((other (make-webview
                           window
                           :init-scripts '("window.everywhere = true;"
                                           ("window.mainOnly = true;" :main-frame-only t))
                           :html "<iframe srcdoc='<p>inner</p>'></iframe>")))
               (prog1 (wait-until
                       (lambda ()
                         (equal "true|true|true|false"
                                (eval-js other "(() => { const f = document.querySelector('iframe'); if (!f || !f.contentWindow.document.body) return ''; const w = f.contentWindow; return [!!window.everywhere, !!window.mainOnly, !!w.everywhere, !!w.mainOnly].join('|'); })()"))))
                 (destroy-webview other))))
      (check "add-init-script takes effect from the next load"
             (let ((other (make-webview window :html "<p>first</p>")))
               (wait-until (lambda () (equal "first" (eval-js other "document.body ? document.body.textContent : ''"))))
               (add-init-script other "window.later = 'added';")
               (load-html other "<p>second</p>")
               (prog1 (wait-until (lambda () (equal "added" (eval-js other "window.later || ''"))))
                 (destroy-webview other))))
      (check "answering a request twice is reported, and only the first answer is sent"
             (let* ((seen nil)
                    (old *error-reporter*)
                    (other (make-webview
                            window
                            :protocols (list (list "twice"
                                                   (lambda (request responder)
                                                     (declare (ignore request))
                                                     (respond responder "<title>first</title>")
                                                     (respond responder "<title>second</title>"))
                                                   :async t)))))
               (setf *error-reporter* (lambda (where c) (declare (ignore where)) (setf seen c)))
               (unwind-protect
                    (progn (load-url other "twice://x/")
                           (prog1 (and (wait-until (lambda () (equal "first" (eval-js other "document.title"))))
                                       (wait-until (lambda () seen))
                                       (search "already answered" (princ-to-string seen)))
                             (destroy-webview other)))
                 (setf *error-reporter* old))))
      (check "no request is left open"
             (wait-until (lambda () (zerop (on-main (lambda () (hash-table-count cl-iris/webview::*open-tasks*)))))))
      (check "iris.post reaches on-message"
             (progn
               (eval-js webview "iris.post({kind: 'posted', n: 3}); 0")
               (wait-until (lambda ()
                             (sb-thread:with-mutex (lock)
                               (find-if (lambda (m) (and (hash-table-p m)
                                                         (equal "posted" (gethash "kind" m))
                                                         (eql 3 (gethash "n" m))))
                                        messages))))))
      (let ((other (make-webview
                    window
                    :html "<title>invoke</title>"
                    :on-invoke (lambda (value)
                                 (cond ((equal value "boom") (error "kaboom"))
                                       ((hash-table-p value)
                                        (let ((answer (make-hash-table :test 'equal)))
                                          (setf (gethash "sum" answer)
                                                (reduce #'+ (gethash "numbers" value)))
                                          answer))
                                       (t (list value value)))))))
        (wait-until (lambda () (equal "invoke" (eval-js other "document.title"))))
        (check "iris.invoke resolves with what on-invoke returns"
               (progn
                 (eval-js other "iris.invoke({numbers: [1, 2, 3]}).then(r => window.result = r.sum); 0")
                 (wait-until (lambda () (eql 6 (eval-js other "window.result || 0"))))))
        (check "iris.invoke carries lists as arrays"
               (progn
                 (eval-js other "iris.invoke('x').then(r => window.pair = r.join('+')); 0")
                 (wait-until (lambda () (equal "x+x" (eval-js other "window.pair || ''"))))))
        (check "an error in on-invoke rejects the Promise with its message, and is reported"
               (let ((reported nil)
                     (old *error-reporter*))
                 (setf *error-reporter* (lambda (where c) (declare (ignore where)) (setf reported c)))
                 (unwind-protect
                      (progn
                        (eval-js other "iris.invoke('boom').catch(e => window.failure = String(e.message || e)); 0")
                        (and (wait-until (lambda () (search "kaboom" (eval-js other "window.failure || ''"))))
                             (search "kaboom" (princ-to-string reported))))
                   (setf *error-reporter* old))))
        (destroy-webview other))
      (check "an asynchronous on-invoke answers later from another thread"
             (let ((other (make-webview
                           window
                           :html "<title>later</title>"
                           :invoke-async t
                           :on-invoke (lambda (value answer)
                                        (sb-thread:make-thread
                                         (lambda () (sleep 0.1) (funcall answer (* 2 value))))))))
               (wait-until (lambda () (equal "later" (eval-js other "document.title"))))
               (eval-js other "iris.invoke(21).then(r => window.doubled = r); 0")
               (prog1 (wait-until (lambda () (eql 42 (eval-js other "window.doubled || 0"))))
                 (destroy-webview other))))
      (check "iris.invoke without a handler rejects"
             (progn
               (eval-js webview "iris.invoke(1).catch(e => window.noHandler = String(e.message || e)); 0")
               (wait-until (lambda () (search "no :on-invoke" (eval-js webview "window.noHandler || ''"))))))
      (let ((other (make-webview window :on-request #'serve :user-agent "cl-iris-test/1"
                                        :url "iris://app/data.txt")))
        (check "a custom user agent reaches navigator and requests"
               (and (wait-until (lambda () (equal "cl-iris-test/1" (eval-js other "navigator.userAgent"))))
                    (wait-until (lambda () (equal "cl-iris-test/1"
                                                  (request-header *last-request* "User-Agent"))))
                    (equal "cl-iris-test/1" (webview-user-agent other))))
        (check "the user agent can change on a live webview"
               (progn
                 (setf (webview-user-agent other) "cl-iris-test/2")
                 (load-url other "iris://app/data.txt")
                 (wait-until (lambda () (equal "cl-iris-test/2" (eval-js other "navigator.userAgent"))))))
        (check "clearing the user agent restores WebKit's"
               (progn
                 (setf (webview-user-agent other) nil)
                 (search "AppleWebKit" (webview-user-agent other))))
        (destroy-webview other))
      (let ((other (make-webview window :devtools t)))
        (check "devtools makes a webview inspectable"
               (webview-devtools-p other))
        (check "devtools can be switched off on a live webview"
               (progn (setf (webview-devtools-p other) nil)
                      (not (webview-devtools-p other))))
        (destroy-webview other))
      (let ((other (make-webview window :navigation-gestures t)))
        (check "navigation gestures can be switched on and off"
               (and (webview-navigation-gestures-p other)
                    (progn (setf (webview-navigation-gestures-p other) nil)
                           (not (webview-navigation-gestures-p other)))))
        (destroy-webview other))
      (let ((other (make-webview window :visible nil :html "<title>hidden</title>")))
        (check "a webview can start hidden and keep running its page"
               (and (not (webview-visible-p other))
                    (wait-until (lambda () (equal "hidden" (eval-js other "document.title"))))))
        (check "a hidden webview can be shown"
               (progn (setf (webview-visible-p other) t)
                      (webview-visible-p other)))
        (destroy-webview other))
      (let ((other (make-webview window :transparent t)))
        (check "a transparent webview draws no background"
               (webview-transparent-p other))
        (check "transparency can be switched off again"
               (progn (setf (webview-transparent-p other) nil)
                      (not (webview-transparent-p other))))
        (destroy-webview other))
      (let ((other (make-webview window :background-color "#ff8800")))
        (check "a background color is set and the white background goes"
               (and (equal '(1d0 0.53d0 0d0 1d0)
                           (mapcar (lambda (x) (/ (fround x 0.01d0) 100)) (webview-background-color other)))
                    (webview-transparent-p other)))
        (check "the background color can change on a live webview"
               (progn (setf (webview-background-color other) '(0 0 1))
                      (equal '(0d0 0d0 1d0 1d0) (webview-background-color other))))
        (destroy-webview other))
      (check "webviews are opaque by default"
             (not (webview-transparent-p webview)))
      (let ((playing (make-webview window :autoplay t))
            (waiting (make-webview window :autoplay nil)))
        (check "autoplay lets media start without a gesture"
               (webview-autoplay-p playing))
        (check "without autoplay, media waits for a gesture"
               (not (webview-autoplay-p waiting)))
        (destroy-webview playing)
        (destroy-webview waiting))
      (let ((private (make-webview window :incognito t :on-request #'serve
                                          :url "iris://app/data.txt"))
            (other-private (make-webview window :incognito t :on-request #'serve
                                                :url "iris://app/data.txt")))
        (check "an incognito webview keeps its data in memory"
               (and (webview-incognito-p private)
                    (not (webview-incognito-p webview))))
        (check "incognito webviews do not share storage"
               (and (wait-until (lambda () (equal "iris://app/data.txt" (eval-js private "location.href"))))
                    (wait-until (lambda () (equal "iris://app/data.txt" (eval-js other-private "location.href"))))
                    (progn (eval-js private "localStorage.setItem('k', 'private'); 0")
                           (equal :null (eval-js other-private "localStorage.getItem('k')")))))
        (destroy-webview private)
        (destroy-webview other-private))
      (let ((other (make-webview window :javascript nil
                                        :html "<title>static</title><script>document.title = 'scripted'</script>")))
        (check "with javascript off, the page's scripts do not run"
               (and (wait-until (lambda () (equal "static" (eval-js other "document.title"))))
                    (progn (sleep 0.2) (equal "static" (eval-js other "document.title")))))
        (destroy-webview other))
      (let ((other (make-webview window :background-throttling :none)))
        (check "background throttling can be turned off"
               (eq :none (webview-background-throttling other)))
        (destroy-webview other))
      (check "an unknown background throttling policy is refused"
             (handler-case (progn (make-webview window :background-throttling :sometimes) nil)
               (error (e) (search "SOMETIMES" (princ-to-string e)))))
      (check "bad options are refused before anything is made"
             (flet ((made () (on-main (lambda () (hash-table-count cl-iris/webview::*routes*)))))
               (let ((before (made)))
                 (and (every (lambda (options)
                               (handler-case (progn (apply #'make-webview window options) nil)
                                 (error () t)))
                             '((:proxy (:ftp "h" 1)) (:zoom -1) (:bounds (0 0 10))
                               (:background-color "#zz")))
                      (= before (made))))))
      (let ((http (make-webview window :incognito t :proxy '(:http "127.0.0.1" 3128)))
            (socks (make-webview window :incognito t :proxy '(:socks5 "127.0.0.1" 1080))))
        (check "an HTTP proxy is set on the webview's store"
               (= 1 (webview-proxy-count http)))
        (check "a SOCKS5 proxy is set on the webview's store"
               (= 1 (webview-proxy-count socks)))
        (destroy-webview http)
        (destroy-webview socks))
      (let* ((port (start-test-server))
             (other (make-webview window :incognito t :proxy (list :http "127.0.0.1" port)
                                         :url "http://proxied.invalid/")))
        (check "a webview's requests really go through its proxy"
               (and (wait-until (lambda () (equal "proxied" (eval-js other "document.title"))))
                    (find "CONNECT proxied.invalid:80" *proxied-lines*
                          :test (lambda (prefix line) (eql 0 (search prefix line))))))
        (destroy-webview other))
      (check "webviews have no proxy by default"
             (zerop (webview-proxy-count webview)))
      (let ((other (make-webview window :accept-first-mouse t)))
        (check "accept-first-mouse lets the first click through"
               (webview-accepts-first-mouse-p other))
        (check "accept-first-mouse can change on a live webview"
               (progn (setf (webview-accepts-first-mouse-p other) nil)
                      (not (webview-accepts-first-mouse-p other))))
        (destroy-webview other))
      (check "webviews do not take the first click by default"
             (not (webview-accepts-first-mouse-p webview)))
      (check "webviews are made from our WKWebView subclass"
             (on-main (lambda () (and (kind-of-p webview "WKWebView")
                                      (kind-of-p webview "CLIrisWebView")))))
      (let* ((panes (make-window :title "cl-iris panes" :width 600 :height 400 :activate nil))
             (left (make-webview panes :bounds '(0 0 200 400) :html "<title>left</title>"))
             (right (make-webview panes :bounds '(200 50 400 300) :html "<title>right</title>")))
        (check "several webviews share one window, each in its bounds"
               (and (equal '(0d0 0d0 200d0 400d0) (webview-bounds left))
                    (equal '(200d0 50d0 400d0 300d0) (webview-bounds right))
                    (wait-until (lambda () (and (equal "left" (eval-js left "document.title"))
                                                (equal "right" (eval-js right "document.title")))))
                    (eql 400 (eval-js right "window.innerWidth"))))
        (check "focus moves between webviews"
               (and (progn (focus-webview left)
                           (and (webview-focused-p left) (not (webview-focused-p right))))
                    (progn (focus-webview right)
                           (and (webview-focused-p right) (not (webview-focused-p left))))))
        (check "focus-parent hands the focus back to the window"
               (progn (focus-webview left)
                      (focus-parent left)
                      (not (webview-focused-p left))))
        (check "a webview made with :focused takes the focus"
               (let ((third (make-webview panes :bounds '(0 0 10 10) :focused t)))
                 (prog1 (and (webview-focused-p third) (not (webview-focused-p right)))
                   (destroy-webview third))))
        (check "a webview can be moved and resized"
               (progn (setf (webview-bounds right) '(250 0 300 200))
                      (and (equal '(250d0 0d0 300d0 200d0) (webview-bounds right))
                           (wait-until (lambda () (eql 300 (eval-js right "window.innerWidth")))))))
        (destroy-webview left)
        (destroy-webview right)
        (close-window panes))
      (check "a webview without bounds fills its window"
             (let ((other (make-webview window)))
               (prog1 (and (multiple-value-bind (width height) (window-content-size window)
                             (equal (list 0d0 0d0 width height) (webview-bounds other)))
                           (handler-case (progn (setf (webview-bounds other) '(0 0 10 10)) nil)
                             (error (e) (search ":BOUNDS" (princ-to-string e)))))
                 (destroy-webview other))))
      (let* ((asked '())
             (other (make-webview window
                                  :protocols (list (list "nav" (lambda (r) (format nil "<title>~A</title>" (request-url r)))))
                                  :on-navigate (lambda (url)
                                                 (push url asked)
                                                 (not (search "blocked" url)))
                                  :url "nav://start/")))
        (check "on-navigate lets a navigation through"
               (and (wait-until (lambda () (equal "nav://start/" (eval-js other "document.title"))))
                    (member "nav://start/" asked :test #'equal)))
        (check "on-navigate can refuse a navigation"
               (progn (eval-js other "location.href = 'nav://blocked/'; 0")
                      (and (wait-until (lambda () (member "nav://blocked/" asked :test #'equal)))
                           (progn (sleep 0.3)
                                  (equal "nav://start/" (eval-js other "location.href"))))))
        (destroy-webview other))
      (let* ((events '())
             (other (make-webview window
                                  :on-request #'serve
                                  :on-page-load (lambda (event url &optional message)
                                                  (declare (ignore message))
                                                  (push (list event url) events))
                                  :url "iris://app/index.html")))
        (check "on-page-load hears a page start and finish"
               (wait-until (lambda ()
                             (equal '((:finished "iris://app/index.html")
                                      (:started "iris://app/index.html"))
                                    (subseq events 0 (min 2 (length events)))))))
        (check "on-page-load hears a load fail"
               (progn (load-url other "https://cl-iris.invalid/")
                      (wait-until (lambda () (eq :failed (first (first events)))))))
        (destroy-webview other))
      ;; Kill the content process as a crash would. _webProcessIdentifier is
      ;; WebKit's own testing hook, not public API.
      (when (on-main (lambda () (responds-to-p webview "_webProcessIdentifier")))
        (flet ((kill (view)
                 (sb-posix:kill (on-main (lambda () (send view "_webProcessIdentifier" :int)))
                                sb-posix:sigkill)))
          (let* ((terminated nil)
                 (outcome nil)
                 (other (make-webview window :html "<title>alive</title>"
                                             :on-web-process-terminated
                                             (lambda (view) (setf terminated view)))))
            (wait-until (lambda () (equal "alive" (eval-js other "document.title"))))
            (eval-js other "new Promise(() => {})" :wait nil
                     :callback (lambda (value message) (setf outcome (list value message))))
            (kill other)
            (check "on-web-process-terminated hears the content process die"
                   (wait-until (lambda () (and terminated (cffi:pointer-eq terminated other)))))
            (check "an eval-js pending when the process dies ends with an error"
                   (wait-until (lambda () (and outcome (second outcome)))))
            (destroy-webview other))
          (let ((other (make-webview window :on-request #'serve :url "iris://app/index.html")))
            (wait-until (lambda () (equal "iris" (eval-js other "document.title"))))
            (eval-js other "window.marker = 1; 0")
            (kill other)
            (check "without a handler, a webview whose process died reloads"
                   (wait-until (lambda () (ignore-errors
                                           (and (equal "iris" (eval-js other "document.title"))
                                                (eq :null (eval-js other "window.marker ?? null")))))))
            (destroy-webview other))))
      (let* ((titles '())
             (other (make-webview window
                                  :html "<title>one</title>"
                                  :on-title-change (lambda (title) (push title titles)))))
        (check "on-title-change hears the title of a new page"
               (wait-until (lambda () (member "one" titles :test #'equal))))
        (check "on-title-change hears a script change the title"
               (progn (eval-js other "document.title = 'two'; 0")
                      (wait-until (lambda () (equal "two" (first titles))))))
        (destroy-webview other))
      (let* ((loads 0)
             (other (make-webview window
                                  :protocols (list (list "hist" (lambda (r)
                                                                  (incf loads)
                                                                  (format nil "<title>~A</title>" (request-url r)))))
                                  :url "hist://one/")))
        (flet ((at (url) (wait-until (lambda () (and (equal url (webview-url other))
                                                     (equal url (eval-js other "document.title")))))))
          (check "webview-url tells where a webview is"
                 (at "hist://one/"))
          (check "a fresh webview cannot go back or forward"
                 (and (not (can-go-back-p other)) (not (can-go-forward-p other))
                      (null (go-back other))))
          (check "going back and forward moves through history"
                 (and (progn (load-url other "hist://two/") (at "hist://two/"))
                      (can-go-back-p other)
                      (go-back other) (at "hist://one/")
                      (can-go-forward-p other)
                      (go-forward other) (at "hist://two/")))
          (check "reload loads the page again"
                 (let ((before loads))
                   (reload other)
                   (wait-until (lambda () (> loads before))))))
        (destroy-webview other))
      (check "webview-url is NIL before anything loads"
             (let ((other (make-webview window)))
               (prog1 (null (webview-url other)) (destroy-webview other))))
      (let ((other (make-webview window :zoom 2 :html "<title>zoom</title>")))
        (check "zoom scales the page's CSS pixels"
               (and (wait-until (lambda () (equal "zoom" (eval-js other "document.title"))))
                    (= 2 (webview-zoom other))
                    (multiple-value-bind (width) (window-content-size window)
                      (eql (round width 2) (eval-js other "window.innerWidth")))))
        (check "zoom can change on a live webview"
               (progn (setf (webview-zoom other) 1)
                      (multiple-value-bind (width) (window-content-size window)
                        (wait-until (lambda () (eql (round width) (eval-js other "window.innerWidth")))))))
        (check "a zoom that is not a positive number is refused"
               (handler-case (progn (setf (webview-zoom other) 0) nil)
                 (error () t)))
        (destroy-webview other))
      (flet ((page (r) (format nil "<title>~A</title><a id=l target=_blank href='blank://two/'>x</a>"
                               (request-url r))))
        (let ((other (make-webview window :protocols (list (list "blank" #'page))
                                          :url "blank://one/")))
          (check "a target=_blank link opens in place by default"
                 (and (wait-until (lambda () (equal "blank://one/" (eval-js other "document.title"))))
                      (progn (eval-js other "document.getElementById('l').click(); 0")
                             (wait-until (lambda () (equal "blank://two/" (webview-url other)))))))
          (destroy-webview other))
        (let* ((asked nil)
               (other (make-webview window :protocols (list (list "blank" #'page))
                                           :on-new-window (lambda (url) (setf asked url) nil)
                                           :url "blank://one/")))
          (check "on-new-window can refuse window.open"
                 (and (wait-until (lambda () (equal "blank://one/" (eval-js other "document.title"))))
                      (progn (eval-js other "window.open('blank://three/'); 0")
                             (wait-until (lambda () (equal "blank://three/" asked))))
                      (progn (sleep 0.2) (equal "blank://one/" (webview-url other)))))
          (destroy-webview other)))
      (let* ((seen '())
             (other (make-webview window
                                  :html "<title>panels</title>"
                                  :on-dialog (lambda (kind message &optional default)
                                               (push (list kind message default) seen)
                                               (case kind
                                                 (:confirm (equal message "yes?"))
                                                 (:prompt (concatenate 'string default "!")))))))
        (wait-until (lambda () (equal "panels" (eval-js other "document.title"))))
        (check "on-dialog hears alert()"
               (progn (eval-js other "alert('hello'); 0")
                      (equal '(:alert "hello" nil) (first seen))))
        (check "on-dialog answers confirm()"
               (and (eq t (eval-js other "confirm('yes?')"))
                    (null (eval-js other "confirm('no?')"))))
        (check "on-dialog answers prompt() with text"
               (equal "abc!" (eval-js other "prompt('name?', 'abc')")))
        (destroy-webview other))
      (let ((other (make-webview window :html "<title>sheets</title>")))
        (flet ((sheet () (on-main (lambda () (let ((s (send window "attachedSheet")))
                                               (unless (cffi:null-pointer-p s) s)))))
               (dismiss (sheet code)
                 (on-main (lambda () (send window "endSheet:returnCode:"
                                           :pointer sheet :long code :void)))))
          (wait-until (lambda () (equal "sheets" (eval-js other "document.title"))))
          (check "without on-dialog, confirm() shows a sheet and hears its answer"
                 (progn
                   (eval-js other "window.answer = confirm('sure?'); 0" :wait nil)
                   (let ((s (wait-until #'sheet)))
                     (and s
                          (progn (dismiss s 1000)
                                 (wait-until (lambda () (eq t (eval-js other "window.answer")))))))))
          (check "cancelling a prompt sheet answers null"
                 (progn
                   (eval-js other "window.typed = prompt('name?', 'x'); 0" :wait nil)
                   (let ((s (wait-until #'sheet)))
                     (and s
                          (progn (dismiss s 1001)
                                 (wait-until (lambda () (eq :null (eval-js other "window.typed"))))))))))
        (destroy-webview other))
      (uiop:with-temporary-file (:pathname chosen :type "txt" :prefix "cl-iris-upload")
        (with-open-file (out chosen :direction :output :if-exists :supersede)
          (write-string "uploaded bytes" out))
        (let* ((asked nil)
               (other (make-webview
                       window
                       :html "<title>files</title><input id=f type=file multiple>"
                       :on-file-dialog (lambda (&key multiple directories)
                                         (setf asked (list multiple directories))
                                         (list chosen)))))
          (wait-until (lambda () (equal "files" (eval-js other "document.title"))))
          (eval-js other "const f = document.getElementById('f'); f.onchange = async () => { window.picked = f.files[0].name + ':' + await f.files[0].text(); }; f.click(); 0")
          (check "on-file-dialog chooses the files for an input"
                 (wait-until (lambda () (equal (format nil "~A:uploaded bytes" (file-namestring chosen))
                                               (eval-js other "window.picked || ''")))))
          (check "on-file-dialog hears what the input accepts"
                 (equal '(t nil) asked))
          (destroy-webview other)))
      (let ((other (make-webview window :html "<title>panel</title><input id=f type=file>")))
        (wait-until (lambda () (equal "panel" (eval-js other "document.title"))))
        (eval-js other "const f = document.getElementById('f'); f.addEventListener('cancel', () => window.cancelled = true); f.click(); 0")
        (check "without on-file-dialog, an open panel sheet asks, and can be cancelled"
               (let ((sheet (wait-until (lambda () (on-main (lambda () (let ((s (send window "attachedSheet")))
                                                                         (unless (cffi:null-pointer-p s) s))))))))
                 (and sheet
                      (on-main (lambda () (kind-of-p sheet "NSOpenPanel")))
                      (progn (on-main (lambda () (send window "endSheet:returnCode:"
                                                       :pointer sheet :long 0 :void)))
                             (wait-until (lambda () (eq t (eval-js other "window.cancelled || false"))))))))
        (destroy-webview other))
      ;; Asking for the real camera would bring up the system's privacy prompt,
      ;; so the delegate is called directly, as WebKit would call it.
      (let* ((asked nil)
             (other (make-webview window :on-permission (lambda (kind origin)
                                                         (setf asked (list kind origin))
                                                         :deny))))
        (flet ((decide (view type)
                 (let ((decision nil))
                   (with-block (block (cffi:callback cl-iris/webview::sheet-ended)
                                      (lambda (value) (setf decision value)))
                     (on-main (lambda ()
                                (send (cl-iris/webview::route view :delegate)
                                      "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
                                      :pointer view :pointer (cffi:null-pointer)
                                      :pointer (cffi:null-pointer) :long type :pointer block
                                      :void))))
                   decision)))
          (check "on-permission decides a request for the microphone"
                 (and (eql 2 (decide other 1)) (equal '(:microphone nil) asked)))
          (check "without on-permission, WebKit prompts as usual"
                 (let ((plain (make-webview window)))
                   (prog1 (eql 0 (decide plain 0))
                     (destroy-webview plain)))))
        (destroy-webview other))
      (let ((other (make-webview window :incognito t :html "<title>jar</title>"
                                        :base-url "https://cl-iris.test/")))
        (flet ((named (name list) (find name list :key (lambda (c) (getf c :name)) :test #'equal)))
          (check "set-cookie stores a cookie that cookies lists"
                 (progn (set-cookie other :name "flavor" :value "oat" :domain "cl-iris.test"
                                          :expires (+ (get-universal-time) 3600) :secure t)
                        (let ((cookie (named "flavor" (cookies other))))
                          (and cookie (equal "oat" (getf cookie :value)) (getf cookie :secure)
                               (integerp (getf cookie :expires))))))
          (check "cookies for a URL are those it would be sent"
                 (and (named "flavor" (cookies other :url "https://www.cl-iris.test/x"))
                      (not (named "flavor" (cookies other :url "http://cl-iris.test/")))
                      (not (named "flavor" (cookies other :url "https://elsewhere.test/")))))
          (check "a page's own cookies are listed"
                 (progn (wait-until (lambda () (equal "jar" (eval-js other "document.title"))))
                        (eval-js other "document.cookie = 'fromPage=1; path=/'; 0")
                        (wait-until (lambda () (named "fromPage" (cookies other))))))
          (check "clear-browsing-data removes cookies and stored data"
                 (progn (set-cookie other :name "crumb" :value "1" :domain "cl-iris.test")
                        (eval-js other "localStorage.setItem('kept', 'yes'); 0")
                        (clear-browsing-data other)
                        (and (not (named "crumb" (cookies other)))
                             (progn (load-html other "<title>jar</title>" :base-url "https://cl-iris.test/")
                                    (wait-until (lambda () (eq :null (eval-js other "localStorage.getItem('kept')"))))))))
          (check "delete-cookie removes a cookie"
                 (progn (set-cookie other :name "flavor" :value "oat" :domain "cl-iris.test")
                        (delete-cookie other (named "flavor" (cookies other)))
                        (not (named "flavor" (cookies other))))))
        (destroy-webview other))
      (uiop:with-temporary-file (:pathname pdf :type "pdf" :prefix "cl-iris-print")
        (delete-file pdf)
        (let ((other (make-webview window :html "<title>print</title><h1>Printed by cl-iris</h1>")))
          (wait-until (lambda () (equal "print" (eval-js other "document.title"))))
          (print-webview other :pdf pdf)
          (check "print-webview writes the page to a PDF file"
                 (wait-until (lambda () (and (probe-file pdf) (pdf-text pdf)
                                             (search "Printed by cl-iris" (pdf-text pdf))))))
          (destroy-webview other)))
      (uiop:with-temporary-file (:pathname saved :type "bin" :prefix "cl-iris-download")
        (delete-file saved)
        (let* ((events '())
               (port (start-test-server
                      (lambda (line)
                        (if (search "/file" line)
                            (values "downloaded bytes" "application/x-cl-iris-test")
                            (values "<title>dl</title>" "text/html")))))
               (home (format nil "http://127.0.0.1:~D/" port))
               (other (make-webview
                       window
                       :on-download (lambda (event url &optional detail)
                                      (push (list event url detail) events)
                                      (when (eq event :started) saved))
                       :url home)))
          (flet ((saw (event) (find event events :key #'first)))
            (wait-until (lambda () (equal "dl" (eval-js other "document.title"))))
            (check "a response WebKit cannot show is downloaded where on-download says"
                   (progn (load-url other (format nil "~Afile" home))
                          (and (wait-until (lambda () (saw :finished)))
                               (equal (list :started (format nil "~Afile" home) "file") (saw :started))
                               (equal "downloaded bytes" (uiop:read-file-string saved)))))
            (setf events '())
            (when (probe-file saved) (delete-file saved))
            (check "a link with the download attribute is downloaded under its name"
                   (progn (eval-js other "const a = document.createElement('a'); a.href = URL.createObjectURL(new Blob(['blob bytes'])); a.download = 'named.bin'; document.body.appendChild(a); a.click(); 0")
                          (and (wait-until (lambda () (saw :finished)))
                               (equal "named.bin" (third (saw :started)))
                               (equal "blob bytes" (uiop:read-file-string saved))))))
          (destroy-webview other)))
      (let* ((events '())
             (other (make-webview window :bounds '(0 0 300 200)
                                         :on-drag-drop (lambda (event paths position)
                                                         (push (list event paths position) events)
                                                         ;; Take every event: passing the
                                                         ;; stand-in on to WebKit would fail.
                                                         t))))
        (multiple-value-bind (width height) (window-content-size window)
          (declare (ignore width))
          (let ((info (on-main (lambda () (test-dragging-info (list "/tmp/one.txt")))))
                (reader (fdefinition 'cl-iris/webview::dragging-location)))
            ;; The webview sits at the window's top-left: window coordinates
            ;; count from the bottom.
            (setf (fdefinition 'cl-iris/webview::dragging-location)
                  (lambda (info) (declare (ignore info)) (make-point 10 (- height 20))))
            (unwind-protect
                 (progn
                   (on-main (lambda ()
                              (send other "draggingEntered:" :pointer info :unsigned-long)
                              (send other "draggingUpdated:" :pointer info :unsigned-long)))
                   (check "on-drag-drop hears files dragged over, with their position"
                          (equal '((:over ("/tmp/one.txt") (10d0 20d0))
                                   (:enter ("/tmp/one.txt") (10d0 20d0)))
                                 events))
                   (check "on-drag-drop can take a drop from the page"
                          (on-main (lambda () (send other "performDragOperation:" :pointer info :bool)))))
              (setf (fdefinition 'cl-iris/webview::dragging-location) reader)
              (on-main (lambda () (release info))))))
        (destroy-webview other))
      (check "webviews are not inspectable by default"
             (not (webview-devtools-p webview)))
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
