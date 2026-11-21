;;;; Webview options: settings on the configuration, made before the webview
;;;; exists, and settings on the webview itself, which can also change later.

(in-package #:cl-iris/webview)

(defun configure (configuration options)
  "Apply the configuration-level OPTIONS (a MAKE-WEBVIEW plist) to
CONFIGURATION, before the webview is made from it. Main thread only."
  (declare (ignorable configuration options))
  configuration)

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
