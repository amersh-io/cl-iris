;;;; The delegate: script messages and custom URL schemes.

(in-package #:cl-iris/webview)

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

;;; WebKit does not check conformance to these protocols, and does not always
;;; register them with the runtime; DEFINE-OBJC-CLASS skips missing ones.

(define-objc-class "CLIrisWebViewDelegate"
    (:protocols ("WKScriptMessageHandler" "WKScriptMessageHandlerWithReply"
                 "WKURLSchemeHandler" "WKNavigationDelegate" "WKUIDelegate"))
  (:method "userContentController:didReceiveScriptMessage:" :void
      (self (controller :pointer) (message :pointer))
    (declare (ignore controller))
    (receive-message message))
  (:method "userContentController:didReceiveScriptMessage:replyHandler:" :void
      (self (controller :pointer) (message :pointer) (reply :pointer))
    (declare (ignore controller))
    (receive-invocation message reply))
  (:method "webView:startURLSchemeTask:" :void
      (self (webview :pointer) (task :pointer))
    (start-task webview task))
  (:method "webView:stopURLSchemeTask:" :void
      (self (webview :pointer) (task :pointer))
    (declare (ignore webview))
    (stop-task task))
  (:method "webView:decidePolicyForNavigationAction:decisionHandler:" :void
      (self (webview :pointer) (action :pointer) (decide :pointer))
    (decide-navigation webview action decide))
  (:method "webView:didStartProvisionalNavigation:" :void
      (self (webview :pointer) (navigation :pointer))
    (declare (ignore navigation))
    (page-load webview :started))
  (:method "webView:didFinishNavigation:" :void
      (self (webview :pointer) (navigation :pointer))
    (declare (ignore navigation))
    (page-load webview :finished))
  (:method "webView:didFailProvisionalNavigation:withError:" :void
      (self (webview :pointer) (navigation :pointer) (error :pointer))
    (declare (ignore navigation))
    (page-load webview :failed error))
  (:method "observeValueForKeyPath:ofObject:change:context:" :void
      (self (key-path :pointer) (object :pointer) (change :pointer) (context :pointer))
    (declare (ignore change context))
    (observed-change key-path object))
  (:method "webView:createWebViewWithConfiguration:forNavigationAction:windowFeatures:" :pointer
      (self (webview :pointer) (configuration :pointer) (action :pointer) (features :pointer))
    (declare (ignore configuration features))
    (new-window-request webview action))
  (:method "webViewWebContentProcessDidTerminate:" :void (self (webview :pointer))
    (web-process-terminated webview))
  (:method "webView:didFailNavigation:withError:" :void
      (self (webview :pointer) (navigation :pointer) (error :pointer))
    (declare (ignore navigation))
    (page-load webview :failed error)))

(defun delegate-class ()
  (find-class* "CLIrisWebViewDelegate"))

;;; Our WKWebView subclass, for behaviour WebKit only offers by overriding.

(define-objc-class "CLIrisWebView" (:superclass "WKWebView")
  (:method "acceptsFirstMouse:" :bool (self (event :pointer))
    (declare (ignore event))
    (and (route self :accept-first-mouse) t)))

(defun webview-class ()
  (find-class* "CLIrisWebView"))
