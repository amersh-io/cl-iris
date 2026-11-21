;;;; The delegate: script messages and custom URL schemes.

(in-package #:cl-iris/webview)

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

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
    (release response)
    (send task "didReceiveData:" :pointer (ns-data octets) :void)
    (send task "didFinish" :void)))

(defun to-octets (body)
  (if (stringp body)
      (sb-ext:string-to-octets body :external-format :utf-8)
      body))

(defun start-task (webview task)
  (let ((url (lisp-string (send (send (send task "request") "URL") "absoluteString")))
        (handler (route webview :on-request)))
    (multiple-value-bind (body content-type)
        (handler-case (and handler (funcall handler url))
          (serious-condition (c)
            (report-error (format nil "on-request for ~A" url) c)
            (values :error)))
      (cond ((eq body :error)
             (respond task 500 "text/plain" (to-octets "Internal error")))
            ((null body)
             (respond task 404 "text/plain" (to-octets "Not found")))
            (t
             (respond task 200 (or content-type "text/html; charset=utf-8")
                      (to-octets body)))))))

(defun receive-message (message)
  (let ((handler (route (send message "webView") :on-message)))
    (when handler
      (handler-case (funcall handler (objc->lisp (send message "body")))
        (serious-condition (c) (report-error "on-message" c))))))

;;; WebKit does not check conformance to these protocols, and does not always
;;; register them with the runtime; DEFINE-OBJC-CLASS skips missing ones.

(define-objc-class "CLIrisWebViewDelegate"
    (:protocols ("WKScriptMessageHandler" "WKURLSchemeHandler"))
  (:method "userContentController:didReceiveScriptMessage:" :void
      (self (controller :pointer) (message :pointer))
    (declare (ignore controller))
    (receive-message message))
  (:method "webView:startURLSchemeTask:" :void
      (self (webview :pointer) (task :pointer))
    (start-task webview task))
  (:method "webView:stopURLSchemeTask:" :void
      (self (webview :pointer) (task :pointer))
    (declare (ignore webview task))))

(defun delegate-class ()
  (find-class* "CLIrisWebViewDelegate"))
