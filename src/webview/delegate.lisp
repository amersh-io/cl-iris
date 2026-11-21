;;;; The delegate: script messages and custom URL schemes.

(in-package #:cl-iris/webview)

;;; The delegate class: one instance per webview answers both script messages
;;; and requests for the custom scheme.

;;; WebKit does not check conformance to these protocols, and does not always
;;; register them with the runtime; DEFINE-OBJC-CLASS skips missing ones.

(define-objc-class "CLIrisWebViewDelegate"
    (:protocols ("WKScriptMessageHandler" "WKScriptMessageHandlerWithReply"
                 "WKURLSchemeHandler" "WKNavigationDelegate" "WKUIDelegate"
                 "WKDownloadDelegate"))
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
  (:method "webView:runJavaScriptAlertPanelWithMessage:initiatedByFrame:completionHandler:" :void
      (self (webview :pointer) (message :pointer) (frame :pointer) (completion :pointer))
    (declare (ignore frame))
    (alert-panel webview message completion))
  (:method "webView:runJavaScriptConfirmPanelWithMessage:initiatedByFrame:completionHandler:" :void
      (self (webview :pointer) (message :pointer) (frame :pointer) (completion :pointer))
    (declare (ignore frame))
    (confirm-panel webview message completion))
  (:method "webView:runJavaScriptTextInputPanelWithPrompt:defaultText:initiatedByFrame:completionHandler:" :void
      (self (webview :pointer) (prompt :pointer) (default :pointer) (frame :pointer)
            (completion :pointer))
    (declare (ignore frame))
    (prompt-panel webview prompt default completion))
  (:method "webView:runOpenPanelWithParameters:initiatedByFrame:completionHandler:" :void
      (self (webview :pointer) (parameters :pointer) (frame :pointer) (completion :pointer))
    (declare (ignore frame))
    (open-panel webview parameters completion))
  (:method "webView:requestMediaCapturePermissionForOrigin:initiatedByFrame:type:decisionHandler:"
      :void
      (self (webview :pointer) (origin :pointer) (frame :pointer) (type :long) (decide :pointer))
    (declare (ignore frame))
    (media-capture-permission webview origin type decide))
  (:method "webView:decidePolicyForNavigationResponse:decisionHandler:" :void
      (self (webview :pointer) (response :pointer) (decide :pointer))
    (declare (ignore webview))
    (decide-response response decide))
  (:method "webView:navigationAction:didBecomeDownload:" :void
      (self (webview :pointer) (action :pointer) (download :pointer))
    (declare (ignore webview action))
    (start-download download))
  (:method "webView:navigationResponse:didBecomeDownload:" :void
      (self (webview :pointer) (response :pointer) (download :pointer))
    (declare (ignore webview response))
    (start-download download))
  (:method "download:decideDestinationUsingResponse:suggestedFilename:completionHandler:" :void
      (self (download :pointer) (response :pointer) (suggested :pointer) (completion :pointer))
    (declare (ignore response))
    (download-destination download suggested completion))
  (:method "downloadDidFinish:" :void (self (download :pointer))
    (download-finished download))
  (:method "download:didFailWithError:resumeData:" :void
      (self (download :pointer) (failure :pointer) (resume-data :pointer))
    (declare (ignore resume-data))
    (download-failed download failure))
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
    (and (route self :accept-first-mouse) t))
  (:method "draggingEntered:" :unsigned-long (self (info :pointer))
    (if (drag-event self :enter info)
        +drag-operation-copy+
        (send-super self "CLIrisWebView" "draggingEntered:" :pointer info :unsigned-long)))
  (:method "draggingUpdated:" :unsigned-long (self (info :pointer))
    (if (drag-event self :over info)
        +drag-operation-copy+
        (send-super self "CLIrisWebView" "draggingUpdated:" :pointer info :unsigned-long)))
  (:method "draggingExited:" :void (self (info :pointer))
    (drag-event self :leave info)
    (send-super self "CLIrisWebView" "draggingExited:" :pointer info :void))
  (:method "performDragOperation:" :bool (self (info :pointer))
    (or (drag-event self :drop info)
        (send-super self "CLIrisWebView" "performDragOperation:" :pointer info :bool))))

(defun webview-class ()
  (find-class* "CLIrisWebView"))
