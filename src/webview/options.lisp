;;;; Webview options: settings on the configuration, made before the webview
;;;; exists, and settings on the webview itself, which can also change later.

(in-package #:cl-iris/webview)

(defun configure (configuration options)
  "Apply the configuration-level OPTIONS (a MAKE-WEBVIEW plist) to
CONFIGURATION, before the webview is made from it. Main thread only."
  (declare (ignorable configuration options))
  configuration)

(defun apply-view-options (webview options)
  "Apply the view-level OPTIONS (a MAKE-WEBVIEW plist) to the new WEBVIEW.
Main thread only."
  (let ((user-agent (getf options :user-agent)))
    (when user-agent
      (send webview "setCustomUserAgent:" :pointer (ns-string user-agent) :void)))
  webview)

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
