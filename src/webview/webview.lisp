;;;; Creating and driving webviews.

(in-package #:cl-iris/webview)

;;; Webviews

;;; Bounds are given from the top-left corner of the window's content area,
;;; as on the web; Cocoa counts from the bottom-left.

(defconstant +view-min-y-margin+ 8)

(defun view-frame (container bounds)
  "The frame, in CONTAINER's coordinates, of BOUNDS: (x y width height) from
CONTAINER's top-left corner."
  (destructuring-bind (x y width height) bounds
    (let ((container-height (rect-height (send container "bounds" (:struct ns-rect)))))
      (make-rect x (- container-height y height) width height))))

(defun webview-bounds (webview)
  "WEBVIEW's position and size within its window, as a list (x y width
height) in points from the top-left corner of the content area."
  (on-main
   (lambda ()
     (let* ((frame (send webview "frame" (:struct ns-rect)))
            (superview (send webview "superview"))
            (window (send webview "window"))
            (height (if (or (cffi:null-pointer-p superview)
                            ;; Filling the window: its frame is the content area.
                            (and (not (cffi:null-pointer-p window))
                                 (cffi:pointer-eq webview (send window "contentView"))))
                        (+ (rect-y frame) (rect-height frame))
                        (rect-height (send superview "bounds" (:struct ns-rect))))))
       (list (rect-x frame)
             (- height (rect-y frame) (rect-height frame))
             (rect-width frame)
             (rect-height frame))))))

(defun (setf webview-bounds) (bounds webview)
  "Move and resize WEBVIEW within its window; see WEBVIEW-BOUNDS."
  (on-main
   (lambda ()
     (let ((superview (send webview "superview")))
       (when (cffi:null-pointer-p superview)
         (error "This webview is not in a window."))
       (when (cffi:pointer-eq webview (send (send webview "window") "contentView"))
         (error "This webview fills its window; make it with :BOUNDS to place it."))
       (send webview "setFrame:" (:struct ns-rect) (view-frame superview bounds) :void))))
  bounds)

(defun focus-webview (webview)
  "Give WEBVIEW the keyboard focus within its window."
  (on-main (lambda () (send (send webview "window") "makeFirstResponder:" :pointer webview :bool))))

(defun focus-parent (webview)
  "Take the keyboard focus away from WEBVIEW, back to its window."
  (on-main (lambda () (send (send webview "window") "makeFirstResponder:"
                            :pointer (cffi:null-pointer) :bool))))

(defun webview-focused-p (webview)
  "True if WEBVIEW, or a view inside it, has its window's keyboard focus."
  (on-main
   (lambda ()
     (let* ((window (send webview "window"))
            (responder (if (cffi:null-pointer-p window)
                           (cffi:null-pointer)
                           (send window "firstResponder"))))
       (and (not (cffi:null-pointer-p responder))
            (kind-of-p responder "NSView")
            (send responder "isDescendantOf:" :pointer webview :bool))))))

(defun make-webview (window &rest options
                     &key on-message (scheme "iris") on-request protocols url headers html
                       (base-url "about:blank")
                     &allow-other-keys)
  "Fill WINDOW with a new WKWebView and return it -- or, with BOUNDS, a list
(x y width height) in points from the top-left corner of the window's content
area, place it there, beside any other webviews in WINDOW.

ON-MESSAGE is called on the main thread with each value a page posts with
iris.post(value) (or window.webkit.messageHandlers.iris.postMessage),
converted with OBJC->LISP.

ON-INVOKE answers iris.invoke(value), which returns a Promise: it is called
on the main thread with the value and returns the answer, converted with
LISP->OBJC; an error it signals rejects the Promise with its message. With
INVOKE-ASYNC, ON-INVOKE is called with the value and a function of
(ANSWER &key ERROR) to call once, later, from any thread.

PROTOCOLS lists custom URL schemes answered by Lisp, each as
(SCHEME HANDLER &key ASYNC). HANDLER is called on the main thread with a
REQUEST for each URL of SCHEME (e.g. \"iris://app/index.html\"). It returns
the body, a string or a vector of octets, and optionally a content type
(default text/html), a status (default 200) and further headers as an alist;
returning NIL answers 404. With ASYNC, HANDLER is called with the REQUEST
and a RESPONDER instead, returns at once, and answers later with RESPOND,
from any thread. ON-REQUEST is shorthand for one synchronous protocol named
SCHEME.

USER-AGENT replaces the user agent string WebKit sends. With DEVTOOLS, Web
Inspector can inspect the webview. With NAVIGATION-GESTURES, swipes go back
and forward. With VISIBLE NIL, the webview starts hidden. With TRANSPARENT,
it draws no background, so a transparent page shows what is behind it;
BACKGROUND-COLOR (\"#rrggbb\", (r g b [a]) or :CLEAR) also stops the white
background, so the window's background color shows through, and is shown
past the page's edges.

With AUTOPLAY, media plays without waiting for a user gesture; with AUTOPLAY
NIL, all media waits for one. With INCOGNITO, cookies, storage and caches
stay in memory, apart from other webviews. With JAVASCRIPT NIL, pages run no
scripts of their own (EVAL-JS and init scripts still run).
ON-NAVIGATE is called with the URL of each navigation before it happens,
including the first load and links; it returns true to let it proceed.
ON-PAGE-LOAD is called with :STARTED or :FINISHED and the URL as a page
loads, or with :FAILED, the URL and an error message.
ON-TITLE-CHANGE is called with the document's title whenever it changes.
ON-WEB-PROCESS-TERMINATED is called with the webview when WebKit's content
process for it dies; without it, the page is reloaded.

With FOCUSED, it takes the keyboard focus. With ACCEPT-FIRST-MOUSE, a click on the webview of an
inactive window reaches the page as well as activating the window.
BACKGROUND-THROTTLING is :SUSPEND, :THROTTLE or :NONE: what happens to the
page while it is not visible (macOS 14 and later). PROXY, (:HTTP host port)
or (:SOCKS5 host port), routes the webview's traffic through a proxy (macOS
14 and later); it applies to the webview's data store, which every
non-INCOGNITO webview shares.

INIT-SCRIPTS run at the start of every document, before the page's own
scripts: each is a string, run in every frame, or (STRING :MAIN-FRAME-ONLY T).

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

(defconstant +inject-at-document-start+ 0)

(defun user-script (source main-frame-only)
  "An autoreleased WKUserScript running SOURCE at document start."
  (autorelease
   (send (send (find-class* "WKUserScript") "alloc")
         "initWithSource:injectionTime:forMainFrameOnly:"
         :pointer (ns-string source)
         :long +inject-at-document-start+
         :bool main-frame-only)))

(defun add-user-script (controller script)
  "Add SCRIPT, a string or (STRING &key MAIN-FRAME-ONLY), to CONTROLLER."
  (destructuring-bind (source &key main-frame-only) (if (stringp script) (list script) script)
    (send controller "addUserScript:" :pointer (user-script source main-frame-only) :void)))

(defun add-init-script (webview script)
  "Run SCRIPT in WEBVIEW at the start of every document from the next load
on. SCRIPT is a string, run in every frame, or (STRING :MAIN-FRAME-ONLY T)."
  (on-main
   (lambda ()
     (add-user-script (send (send webview "configuration") "userContentController")
                      script)))
  nil)

(defun %make-webview (window options)
  (let ((configuration (send (send (find-class* "WKWebViewConfiguration") "alloc") "init"))
        (delegate (send (send (delegate-class) "alloc") "init")))
    (let ((controller (send configuration "userContentController")))
      (send controller "addScriptMessageHandler:name:"
            :pointer delegate :pointer (ns-string *message-handler-name*) :void)
      (send controller "addScriptMessageHandlerWithReply:contentWorld:name:"
            :pointer delegate
            :pointer (send (find-class* "WKContentWorld") "pageWorld")
            :pointer (ns-string *invoke-handler-name*)
            :void)
      (add-user-script controller *bridge-script*)
      (dolist (script (getf options :init-scripts))
        (add-user-script controller script)))
    (loop for (scheme) in (getf options :protocols)
          do (send configuration "setURLSchemeHandler:forURLScheme:"
                   :pointer delegate :pointer (ns-string scheme) :void))
    (configure configuration options)
    (let* ((content (send window "contentView"))
           (bounds (getf options :bounds))
           (webview (send (send (webview-class) "alloc")
                          "initWithFrame:configuration:"
                          (:struct ns-rect)
                          (if bounds
                              (view-frame content bounds)
                              (send content "frame" (:struct ns-rect)))
                          :pointer configuration)))
      ;; The user content controller keeps the delegate alive; the webview
      ;; refers to it weakly, and DESTROY-WEBVIEW detaches it.
      (send webview "setNavigationDelegate:" :pointer delegate :void)
      (observe-title webview delegate)
      ;; The configuration and its user content controller retain what they need.
      (release configuration)
      ;; Our own reference to the delegate stays until DESTROY-WEBVIEW: the
      ;; webview holds it only weakly, and the title observation must outlive
      ;; the handlers that otherwise keep it.
      (setf (gethash (cffi:pointer-address webview) *routes*)
            (list* :delegate delegate options))
      (apply-view-options webview options)
      (cond (bounds
             ;; Keep the same distance from the top as the window resizes.
             (send webview "setAutoresizingMask:" :unsigned-long +view-min-y-margin+ :void)
             (send content "addSubview:" :pointer webview :void))
            (t (send window "setContentView:" :pointer webview :void)))
      (when (getf options :focused)
        (send window "makeFirstResponder:" :pointer webview :bool))
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
     (let ((delegate (route webview :delegate)))
       (stop-observing-title webview delegate)
       (send webview "setNavigationDelegate:" :pointer (cffi:null-pointer) :void)
       (remhash (cffi:pointer-address webview) *routes*)
       (release delegate))
     (let ((controller (send (send webview "configuration") "userContentController")))
       (send controller "removeScriptMessageHandlerForName:"
             :pointer (ns-string *message-handler-name*) :void)
       (send controller "removeScriptMessageHandlerForName:contentWorld:"
             :pointer (ns-string *invoke-handler-name*)
             :pointer (send (find-class* "WKContentWorld") "pageWorld")
             :void))
     (send webview "removeFromSuperview" :void)
     (release webview)))
  nil)
