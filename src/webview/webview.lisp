;;;; Creating and driving webviews.

(in-package #:cl-iris/webview)

;;; Webviews

(defun make-webview (window &rest options
                     &key on-message (scheme "iris") on-request protocols url headers html
                       (base-url "about:blank")
                     &allow-other-keys)
  "Fill WINDOW with a new WKWebView and return it.

ON-MESSAGE is called on the main thread with each value a page posts to
window.webkit.messageHandlers.iris, converted with OBJC->LISP.

PROTOCOLS lists custom URL schemes answered by Lisp, each as
(SCHEME HANDLER &key ASYNC). HANDLER is called on the main thread with a
REQUEST for each URL of SCHEME (e.g. \"iris://app/index.html\"). It returns
the body, a string or a vector of octets, and optionally a content type
(default text/html), a status (default 200) and further headers as an alist;
returning NIL answers 404. With ASYNC, HANDLER is called with the REQUEST
and a RESPONDER instead, returns at once, and answers later with RESPOND,
from any thread. ON-REQUEST is shorthand for one synchronous protocol named
SCHEME.

If URL is given, it is loaded, with HEADERS (an alist); or else HTML, a string, is shown as if
loaded from BASE-URL."
  (declare (ignore on-message))
  (when (and url html)
    (error "Give MAKE-WEBVIEW a URL or HTML, not both."))
  (let* ((protocols (append (when on-request (list (list scheme on-request)))
                            protocols))
         (options (list* :protocols (normalize-protocols protocols)
                         (remove-keys options :protocols :on-request :scheme
                                      :url :headers :html :base-url)))
         (webview (on-main (lambda () (%make-webview window options)))))
    (cond (url (load-url webview url :headers headers))
          (html (load-html webview html :base-url base-url)))
    webview))

(defun remove-keys (plist &rest keys)
  (loop for (key value) on plist by #'cddr
        unless (member key keys) collect key and collect value))

(defun normalize-protocols (protocols)
  "Check PROTOCOLS before WebKit sees them: WebKit raises an Objective-C
exception, which would abort the process, for a scheme it handles itself or
one registered twice."
  (let ((seen '()))
    (loop for (scheme handler . options) in protocols
          for name = (string-downcase scheme)
          do (when (member name seen :test #'string=)
               (error "The URL scheme ~S is given twice." scheme))
             (when (on-main (lambda ()
                              (send (find-class* "WKWebView") "handlesURLScheme:"
                                    :pointer (ns-string name) :bool)))
               (error "WebKit handles the URL scheme ~S itself; choose another." scheme))
             (push name seen)
          collect (list* name handler options))))

(defun %make-webview (window options)
  (let ((configuration (send (send (find-class* "WKWebViewConfiguration") "alloc") "init"))
        (delegate (send (send (delegate-class) "alloc") "init")))
    (send (send configuration "userContentController")
          "addScriptMessageHandler:name:"
          :pointer delegate :pointer (ns-string *message-handler-name*) :void)
    (loop for (scheme) in (getf options :protocols)
          do (send configuration "setURLSchemeHandler:forURLScheme:"
                   :pointer delegate :pointer (ns-string scheme) :void))
    (let ((webview (send (send (find-class* "WKWebView") "alloc")
                         "initWithFrame:configuration:"
                         (:struct ns-rect)
                         (send (send window "contentView") "frame"
                               (:struct ns-rect))
                         :pointer configuration)))
      ;; The configuration and its user content controller retain what they need.
      (release configuration)
      (release delegate)
      (setf (gethash (cffi:pointer-address webview) *routes*) options)
      (send window "setContentView:" :pointer webview :void)
      webview)))

(defun ns-url (url)
  "An NSURL for the absolute URL string URL, or an error."
  (let ((object (send (find-class* "NSURL") "URLWithString:" :pointer (ns-string url))))
    ;; Recent Foundation percent-encodes rather than rejecting, so also insist
    ;; on a scheme: a relative URL has nowhere to load from.
    (when (or (cffi:null-pointer-p object)
              (cffi:null-pointer-p (send object "scheme")))
      (error "Not a valid absolute URL: ~S" url))
    object))

(defun url-request (url headers)
  "An NSURLRequest for URL carrying HEADERS, an alist."
  (let ((request (send (find-class* "NSMutableURLRequest") "requestWithURL:"
                       :pointer (ns-url url))))
    (loop for (name . value) in headers
          do (send request "setValue:forHTTPHeaderField:"
                   :pointer (ns-string (princ-to-string value))
                   :pointer (ns-string name)
                   :void))
    request))

(defun load-url (webview url &key headers)
  "Start loading URL in WEBVIEW, sending HEADERS (an alist) with the request."
  (on-main
   (lambda ()
     (send webview "loadRequest:" :pointer (url-request url headers))))
  nil)

(defun load-html (webview html &key (base-url "about:blank"))
  "Show the string HTML in WEBVIEW."
  (on-main
   (lambda ()
     (send webview "loadHTMLString:baseURL:"
           :pointer (ns-string html)
           :pointer (ns-url base-url))))
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
     (release webview)))
  nil)
