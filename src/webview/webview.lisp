;;;; Creating and driving webviews.

(in-package #:cl-iris/webview)

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
