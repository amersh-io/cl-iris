;;;; Webview options: settings on the configuration, made before the webview
;;;; exists, and settings on the webview itself, which can also change later.

(in-package #:cl-iris/webview)

(defvar *configuration-options* '()
  "(KEYWORD . SETTER) for each configuration-level option; SETTER takes the
WKWebViewConfiguration and the value, on the main thread.")

(defmacro define-configuration-option (keyword (configuration value) &body body)
  "Define the configuration-level MAKE-WEBVIEW option KEYWORD, set by BODY
before the webview is made."
  `(progn
     (setf *configuration-options*
           (append (remove ,keyword *configuration-options* :key #'car)
                   (list (cons ,keyword (lambda (,configuration ,value) ,@body)))))
     ,keyword))

(defun configure (configuration options)
  "Apply the configuration-level OPTIONS (a MAKE-WEBVIEW plist) to
CONFIGURATION, before the webview is made from it. Main thread only."
  (loop for (keyword . setter) in *configuration-options*
        for value = (getf options keyword '%absent)
        unless (eq value '%absent)
          do (funcall setter configuration value))
  configuration)

(defun configuration (webview)
  "WEBVIEW's configuration (a copy: changing it does not change WEBVIEW)."
  (send webview "configuration"))

;;; Media

(defconstant +media-types-none+ 0)
(defconstant +media-types-all+ (1- (expt 2 64)))

(define-configuration-option :autoplay (configuration autoplay)
  (send configuration "setMediaTypesRequiringUserActionForPlayback:"
        :unsigned-long (if autoplay +media-types-none+ +media-types-all+)
        :void))

(defun webview-autoplay-p (webview)
  "True if WEBVIEW plays audio and video without waiting for a user gesture."
  (on-main
   (lambda ()
     (= +media-types-none+
        (send (configuration webview) "mediaTypesRequiringUserActionForPlayback"
              :unsigned-long)))))

;;; View-level settings are kept in *VIEW-OPTIONS*: each knows how to set
;;; itself on a webview, and MAKE-WEBVIEW applies those it is given.

(defvar *view-options* '()
  "(KEYWORD . SETTER) for each view-level option; SETTER takes the webview
and the value, on the main thread.")

(defmacro define-view-option (keyword (webview value) &body body)
  "Define the view-level MAKE-WEBVIEW option KEYWORD, set by BODY."
  `(progn
     (setf *view-options*
           (append (remove ,keyword *view-options* :key #'car)
                   (list (cons ,keyword (lambda (,webview ,value) ,@body)))))
     ,keyword))

(defun apply-view-options (webview options)
  "Apply the view-level OPTIONS (a MAKE-WEBVIEW plist) to the new WEBVIEW.
Main thread only."
  (loop for (keyword . setter) in *view-options*
        for value = (getf options keyword '%absent)
        unless (eq value '%absent)
          do (funcall setter webview value))
  webview)

(defmacro define-webview-flag (name selector setter keyword &optional documentation)
  "Define the boolean accessor NAME for the webview property read by SELECTOR
and written by SETTER, and the MAKE-WEBVIEW option KEYWORD that sets it."
  `(progn
     (defun ,name (webview)
       ,@(when documentation (list documentation))
       (on-main (lambda () (send webview ,selector :bool))))
     (defun (setf ,name) (value webview)
       (on-main (lambda () (send webview ,setter :bool (and value t) :void)))
       value)
     (define-view-option ,keyword (webview value)
       (send webview ,setter :bool (and value t) :void))))

(define-view-option :user-agent (webview user-agent)
  (when user-agent
    (send webview "setCustomUserAgent:" :pointer (ns-string user-agent) :void)))

(define-webview-flag webview-devtools-p "isInspectable" "setInspectable:" :devtools
  "True if WEBVIEW can be inspected with Web Inspector (Safari's Develop menu,
or Inspect Element in its context menu).")

;;; Accessors

(defun webview-user-agent (webview)
  "The user agent WEBVIEW sends: its custom one if set, else WebKit's."
  (on-main
   (lambda ()
     (let ((custom (send webview "customUserAgent")))
       (if (or (cffi:null-pointer-p custom) (zerop (send custom "length" :unsigned-long)))
           (objc->lisp (send webview "valueForKey:" :pointer (ns-string "userAgent")))
           (lisp-string custom))))))

(defun (setf webview-user-agent) (user-agent webview)
  "Make WEBVIEW send USER-AGENT from its next request on; NIL restores WebKit's."
  (on-main
   (lambda ()
     (send webview "setCustomUserAgent:"
           :pointer (if user-agent (ns-string user-agent) (cffi:null-pointer))
           :void)))
  user-agent)

(define-webview-flag webview-navigation-gestures-p
    "allowsBackForwardNavigationGestures" "setAllowsBackForwardNavigationGestures:"
    :navigation-gestures
  "True if horizontal swipes on WEBVIEW go back and forward in its history.")

(defun webview-visible-p (webview)
  "True unless WEBVIEW has been hidden."
  (on-main (lambda () (not (send webview "isHidden" :bool)))))

(defun (setf webview-visible-p) (visible webview)
  "Show or hide WEBVIEW; a hidden webview keeps running its page."
  (on-main (lambda () (send webview "setHidden:" :bool (not visible) :void)))
  visible)

(define-view-option :visible (webview visible)
  (send webview "setHidden:" :bool (not visible) :void))

;;; Transparency: WKWebView has no public switch for its opaque background on
;;; macOS; its drawsBackground key, set through key-value coding, is what
;;; WebKit's own clients use.

(defun set-draws-background (webview draws)
  (send webview "setValue:forKey:"
        :pointer (lisp->objc (if draws t :false))
        :pointer (ns-string "drawsBackground")
        :void))

(defun webview-transparent-p (webview)
  "True if WEBVIEW draws no background of its own, letting what is behind it
show through wherever the page itself is transparent."
  (on-main
   (lambda ()
     (not (objc->lisp (send webview "valueForKey:" :pointer (ns-string "drawsBackground")))))))

(defun (setf webview-transparent-p) (transparent webview)
  (on-main (lambda () (set-draws-background webview (not transparent))))
  transparent)

(define-view-option :transparent (webview transparent)
  (set-draws-background webview (not transparent)))

;;; Storage

(define-configuration-option :incognito (configuration incognito)
  (when incognito
    (send configuration "setWebsiteDataStore:"
          :pointer (send (find-class* "WKWebsiteDataStore") "nonPersistentDataStore")
          :void)))

(defun webview-incognito-p (webview)
  "True if WEBVIEW keeps cookies, storage and caches in memory only, apart
from every other webview, and forgets them when it goes."
  (on-main
   (lambda ()
     (not (send (send (configuration webview) "websiteDataStore") "isPersistent" :bool)))))

;;; Scripts

(define-configuration-option :javascript (configuration enabled)
  (send (send configuration "defaultWebpagePreferences")
        "setAllowsContentJavaScript:" :bool (and enabled t) :void))

;;; Background throttling (macOS 14 and later)

(defparameter *scheduling-policies* '((:suspend . 0) (:throttle . 1) (:none . 2))
  "WKInactiveSchedulingPolicy values: what WebKit does with an inactive page.")

(define-configuration-option :background-throttling (configuration policy)
  (let ((preferences (send configuration "preferences"))
        (value (or (cdr (assoc policy *scheduling-policies*))
                   (error "Background throttling is one of ~{~S~^, ~}, not ~S."
                          (mapcar #'car *scheduling-policies*) policy))))
    (if (responds-to-p preferences "setInactiveSchedulingPolicy:")
        (send preferences "setInactiveSchedulingPolicy:" :long value :void)
        (warn "Background throttling needs macOS 14 or later; ignored."))))

(defun webview-background-throttling (webview)
  "What WebKit does with WEBVIEW's page while it is not visible: :SUSPEND it,
:THROTTLE its timers, or :NONE. NIL before macOS 14."
  (on-main
   (lambda ()
     (let ((preferences (send (configuration webview) "preferences")))
       (when (responds-to-p preferences "inactiveSchedulingPolicy")
         (car (rassoc (send preferences "inactiveSchedulingPolicy" :long)
                      *scheduling-policies*)))))))

;;; Proxies (macOS 14 and later)

(cffi:define-foreign-library network
  (:darwin "/System/Library/Frameworks/Network.framework/Network"))

(cffi:use-foreign-library network)

(defun proxy-configuration (proxy)
  "A retained nw_proxy_config_t for PROXY, (:HTTP host port) or
(:SOCKS5 host port)."
  (destructuring-bind (kind host port) proxy
    (let ((endpoint (cffi:foreign-funcall "nw_endpoint_create_host"
                                          :string host :string (princ-to-string port)
                                          :pointer)))
      (unwind-protect
           (ecase kind
             (:http (cffi:foreign-funcall "nw_proxy_config_create_http_connect"
                                          :pointer endpoint :pointer (cffi:null-pointer)
                                          :pointer))
             (:socks5 (cffi:foreign-funcall "nw_proxy_config_create_socksv5"
                                            :pointer endpoint :pointer)))
        (release endpoint)))))

;; Defined after :INCOGNITO, so that it applies to the store that one chose.
(define-configuration-option :proxy (configuration proxy)
  (when proxy
    (let ((store (send configuration "websiteDataStore")))
      (unless (responds-to-p store "setProxyConfigurations:")
        (error "A proxy needs macOS 14 or later."))
      (let ((proxy-configuration (proxy-configuration proxy)))
        (send store "setProxyConfigurations:"
              :pointer (send (find-class* "NSArray") "arrayWithObject:"
                             :pointer proxy-configuration)
              :void)
        (release proxy-configuration)))))

(defun webview-proxy-count (webview)
  "How many proxies the data store of WEBVIEW routes through."
  (on-main
   (lambda ()
     (let ((store (send (configuration webview) "websiteDataStore")))
       (if (responds-to-p store "proxyConfigurations")
           (send (send store "proxyConfigurations") "count" :unsigned-long)
           0)))))

(defun webview-accepts-first-mouse-p (webview)
  "True if a click on WEBVIEW in an inactive window also reaches the page."
  (on-main (lambda () (send webview "acceptsFirstMouse:" :pointer (cffi:null-pointer) :bool))))

(defun (setf webview-accepts-first-mouse-p) (accept webview)
  (on-main (lambda () (setf (getf (gethash (cffi:pointer-address webview) *routes*)
                                  :accept-first-mouse)
                            (and accept t))))
  accept)
