;;;; The delegate: script messages and custom URL schemes.

(in-package #:cl-iris/webview)

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

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
    (declare (ignore webview))
    (stop-task task)))

(defun delegate-class ()
  (find-class* "CLIrisWebViewDelegate"))
