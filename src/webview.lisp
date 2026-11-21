;;;; cl-iris/webview -- WKWebView with a two-way bridge to Lisp.
;;;;
;;;; JavaScript -> Lisp: window.webkit.messageHandlers.iris.postMessage(x)
;;;;   calls the webview's ON-MESSAGE function on the main thread.
;;;; Lisp -> JavaScript: EVAL-JS.
;;;; Pages from Lisp: a custom URL scheme whose requests ON-REQUEST answers.

(defpackage #:cl-iris/webview
  (:use #:cl #:cl-iris/objc #:cl-iris/window)
  (:import-from #:cl-iris/window #:register-task #:take-task)
  (:export #:make-webview
           #:destroy-webview
           #:load-url
           #:load-html
           #:eval-js
           #:javascript-error))

(in-package #:cl-iris/webview)

(cffi:define-foreign-library webkit
  (:darwin "/System/Library/Frameworks/WebKit.framework/WebKit"))

(cffi:use-foreign-library webkit)

(defparameter *message-handler-name* "iris"
  "The name pages post to: window.webkit.messageHandlers.iris.")

;;; Each webview's Lisp functions, keyed by the webview's address. Objective-C
;;; objects never move, so the address is a stable key. Main thread only.

(defvar *routes* (make-hash-table))

(defun route (webview key)
  (getf (gethash (cffi:pointer-address webview) *routes*) key))

;;; Objective-C values to Lisp

(defun objc->lisp (object)
  "Strings and numbers become Lisp strings and numbers (booleans become 1
and 0); null becomes NIL; anything else becomes its description."
  (cond ((or (cffi:null-pointer-p object) (kind-of-p object "NSNull")) nil)
        ((kind-of-p object "NSString") (lisp-string object))
        ((kind-of-p object "NSNumber")
         (let ((d (send object "doubleValue" :double)))
           (if (and (< (abs d) 1d15) (= d (ftruncate d))) (truncate d) d)))
        (t (lisp-string (send object "description")))))

(defun report (where condition)
  (format *error-output* "~&;; cl-iris: error in ~A: ~A~%" where condition))

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

(cffi:defcallback did-receive-script-message :void
    ((self :pointer) (cmd :pointer) (controller :pointer) (message :pointer))
  (declare (ignore self cmd controller))
  (let ((handler (route (send message "webView") :on-message)))
    (when handler
      (handler-case (funcall handler (objc->lisp (send message "body")))
        (serious-condition (c) (report "on-message" c))))))

(defun ns-data (octets)
  (let ((octets (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (cffi:with-pointer-to-vector-data (bytes octets)
      (send (find-class* "NSData") "dataWithBytes:length:"
            :pointer bytes :unsigned-long (length octets)))))

(defun respond (task status content-type octets)
  (let* ((url (send (send task "request") "URL"))
         (headers (send (find-class* "NSDictionary") "dictionaryWithObject:forKey:"
                        :pointer (ns-string content-type)
                        :pointer (ns-string "Content-Type")))
         (response (send (send (find-class* "NSHTTPURLResponse") "alloc")
                         "initWithURL:statusCode:HTTPVersion:headerFields:"
                         :pointer url :long status
                         :pointer (ns-string "HTTP/1.1") :pointer headers)))
    (send task "didReceiveResponse:" :pointer response :void)
    (send response "release" :void)
    (send task "didReceiveData:" :pointer (ns-data octets) :void)
    (send task "didFinish" :void)))

(defun to-octets (body)
  (if (stringp body)
      (sb-ext:string-to-octets body :external-format :utf-8)
      body))

(cffi:defcallback start-url-scheme-task :void
    ((self :pointer) (cmd :pointer) (webview :pointer) (task :pointer))
  (declare (ignore self cmd))
  (let ((url (lisp-string (send (send (send task "request") "URL") "absoluteString")))
        (handler (route webview :on-request)))
    (multiple-value-bind (body content-type)
        (handler-case (and handler (funcall handler url))
          (serious-condition (c)
            (report (format nil "on-request for ~A" url) c)
            (values :error)))
      (cond ((eq body :error)
             (respond task 500 "text/plain" (to-octets "Internal error")))
            ((null body)
             (respond task 404 "text/plain" (to-octets "Not found")))
            (t
             (respond task 200 (or content-type "text/html; charset=utf-8")
                      (to-octets body)))))))

(cffi:defcallback stop-url-scheme-task :void
    ((self :pointer) (cmd :pointer) (webview :pointer) (task :pointer))
  (declare (ignore self cmd webview task)))

(defun delegate-class ()
  (let ((class (ensure-class "CLIrisWebViewDelegate" "NSObject")))
    (add-protocol class "WKScriptMessageHandler")
    (add-protocol class "WKURLSchemeHandler")
    (set-method class "userContentController:didReceiveScriptMessage:"
                (cffi:callback did-receive-script-message) "v@:@@")
    (set-method class "webView:startURLSchemeTask:"
                (cffi:callback start-url-scheme-task) "v@:@@")
    (set-method class "webView:stopURLSchemeTask:"
                (cffi:callback stop-url-scheme-task) "v@:@@")
    class))

;;; Webviews

(defun make-webview (window &key on-message (scheme "iris") on-request url)
  "Fill WINDOW with a new WKWebView and return it.

ON-MESSAGE is called on the main thread with each value a page posts to
window.webkit.messageHandlers.iris (strings and numbers arrive as such).

ON-REQUEST is called on the main thread with the URL of each request for
SCHEME (e.g. \"iris://app/index.html\"). It returns the body, a string or a
vector of octets, and optionally a content type (default text/html);
returning NIL answers 404.

If URL is given, it is loaded."
  (let ((webview (on-main (lambda () (%make-webview window on-message scheme on-request)))))
    (when url
      (load-url webview url))
    webview))

(defun %make-webview (window on-message scheme on-request)
  (let ((configuration (send (send (find-class* "WKWebViewConfiguration") "alloc") "init"))
        (delegate (send (send (delegate-class) "alloc") "init")))
    (send (send configuration "userContentController")
          "addScriptMessageHandler:name:"
          :pointer delegate :pointer (ns-string *message-handler-name*) :void)
    (when on-request
      (send configuration "setURLSchemeHandler:forURLScheme:"
            :pointer delegate :pointer (ns-string scheme) :void))
    (let ((webview (send (send (find-class* "WKWebView") "alloc")
                         "initWithFrame:configuration:"
                         (:struct cl-iris/window::ns-rect)
                         (send (send window "contentView") "frame"
                               (:struct cl-iris/window::ns-rect))
                         :pointer configuration)))
      ;; The configuration and its user content controller retain what they need.
      (send configuration "release" :void)
      (send delegate "release" :void)
      (setf (gethash (cffi:pointer-address webview) *routes*)
            (list :on-message on-message :on-request on-request))
      (send window "setContentView:" :pointer webview :void)
      webview)))

(defun load-url (webview url)
  "Start loading URL in WEBVIEW."
  (on-main
   (lambda ()
     (send webview "loadRequest:"
           :pointer (send (find-class* "NSURLRequest") "requestWithURL:"
                          :pointer (send (find-class* "NSURL") "URLWithString:"
                                         :pointer (ns-string url))))))
  nil)

(defun load-html (webview html &key (base-url "about:blank"))
  "Show the string HTML in WEBVIEW."
  (on-main
   (lambda ()
     (send webview "loadHTMLString:baseURL:"
           :pointer (ns-string html)
           :pointer (send (find-class* "NSURL") "URLWithString:" :pointer (ns-string base-url)))))
  nil)

(defun destroy-webview (webview)
  "Detach WEBVIEW from its window and release it."
  (on-main
   (lambda ()
     (remhash (cffi:pointer-address webview) *routes*)
     (send (send (send webview "configuration") "userContentController")
           "removeScriptMessageHandlerForName:"
           :pointer (ns-string *message-handler-name*) :void)
     (send webview "removeFromSuperview" :void)
     (send webview "release" :void)))
  nil)

;;; Evaluating JavaScript
;;;
;;; -evaluateJavaScript:completionHandler: takes a block. We build one by hand
;;; in foreign memory, marked global so the runtime neither copies nor frees
;;; it. Its last word holds the integer id of the Lisp function to call.
;;;
;;;   0 isa   8 flags, reserved   16 invoke   24 descriptor   32 id
;;;   40 descriptor: reserved, size

(defconstant +block-is-global+ (ash 1 28))
(defconstant +block-size+ 40)

(define-condition javascript-error (error)
  ((message :initarg :message :reader javascript-error-message))
  (:report (lambda (c stream)
             (format stream "JavaScript error: ~A" (javascript-error-message c)))))

(cffi:defcallback js-completion :void
    ((block :pointer) (result :pointer) (error :pointer))
  (let ((function (take-task (cffi:mem-ref block :int64 32))))
    ;; WebKit releases the block after calling it, so free it only later.
    (on-main (lambda () (cffi:foreign-free block)) :wait nil)
    (when function
      (handler-case
          (funcall function
                   (objc->lisp result)
                   (unless (cffi:null-pointer-p error)
                     (lisp-string (send error "localizedDescription"))))
        (serious-condition (c) (report "eval-js callback" c))))))

(defun make-completion-block (function)
  (let ((block (cffi:foreign-alloc :uint8 :count (+ +block-size+ 16))))
    (setf (cffi:mem-ref block :pointer 0) (cffi:foreign-symbol-pointer "_NSConcreteGlobalBlock")
          (cffi:mem-ref block :int32 8) +block-is-global+
          (cffi:mem-ref block :int32 12) 0
          (cffi:mem-ref block :pointer 16) (cffi:callback js-completion)
          (cffi:mem-ref block :pointer 24) (cffi:inc-pointer block +block-size+)
          (cffi:mem-ref block :int64 32) (register-task function)
          (cffi:mem-ref block :uint64 40) 0
          (cffi:mem-ref block :uint64 48) +block-size+)
    block))

(defun eval-js (webview script &key (wait t) callback)
  "Evaluate SCRIPT in WEBVIEW.

With WAIT (the default), block until it finishes and return its value
converted to Lisp, or signal JAVASCRIPT-ERROR. Waiting is not possible on the
main thread, which has to run the script.

Without WAIT, return NIL at once; CALLBACK, if given, is later called on the
main thread with the value and an error message (or NIL)."
  (cond (wait
         (when (main-thread-p)
           (error "EVAL-JS cannot wait on the main thread; pass :WAIT NIL and a :CALLBACK."))
         (let ((done (sb-thread:make-semaphore :name "cl-iris eval-js"))
               (value nil)
               (message nil))
           (eval-js webview script
                    :wait nil
                    :callback (lambda (v m)
                                (setf value v message m)
                                (sb-thread:signal-semaphore done)))
           (sb-thread:wait-on-semaphore done)
           (if message
               (error 'javascript-error :message message)
               value)))
        (t
         (let ((callback (or callback
                             (lambda (value message)
                               (declare (ignore value))
                               (when message (report "eval-js" message))))))
           (on-main
            (lambda ()
              (send webview "evaluateJavaScript:completionHandler:"
                    :pointer (ns-string script)
                    :pointer (make-completion-block callback)
                    :void))
            :wait nil))
         nil)))
