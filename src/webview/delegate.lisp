;;;; The delegate: script messages and custom URL schemes.

(in-package #:cl-iris/webview)

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

(cffi:defcallback did-receive-script-message :void
    ((self :pointer) (cmd :pointer) (controller :pointer) (message :pointer))
  (declare (ignore self cmd controller))
  (let ((handler (route (send message "webView") :on-message)))
    (when handler
      (handler-case (funcall handler (objc->lisp (send message "body")))
        (serious-condition (c) (report-error "on-message" c))))))

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

(cffi:defcallback start-url-scheme-task :void
    ((self :pointer) (cmd :pointer) (webview :pointer) (task :pointer))
  (declare (ignore self cmd))
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

(cffi:defcallback stop-url-scheme-task :void
    ((self :pointer) (cmd :pointer) (webview :pointer) (task :pointer))
  (declare (ignore self cmd webview task)))

(defun delegate-class ()
  (let ((class (ensure-class "CLIrisWebViewDelegate" "NSObject")))
    ;; WebKit does not check conformance, and does not always register
    ;; these protocols with the runtime.
    (add-protocol class "WKScriptMessageHandler" :errorp nil)
    (add-protocol class "WKURLSchemeHandler" :errorp nil)
    (set-method class "userContentController:didReceiveScriptMessage:"
                (cffi:callback did-receive-script-message) "v@:@@")
    (set-method class "webView:startURLSchemeTask:"
                (cffi:callback start-url-scheme-task) "v@:@@")
    (set-method class "webView:stopURLSchemeTask:"
                (cffi:callback stop-url-scheme-task) "v@:@@")
    class))
