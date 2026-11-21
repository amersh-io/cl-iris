;;;; Loading WebKit; per-webview Lisp functions.

(in-package #:cl-iris/webview)

(cffi:define-foreign-library webkit
  (:darwin "/System/Library/Frameworks/WebKit.framework/WebKit"))

(cffi:use-foreign-library webkit)

(defparameter *message-handler-name* "iris"
  "The name pages post to: window.webkit.messageHandlers.iris.")

;;; Every webview made by MAKE-WEBVIEW is a WEBVIEW object, kept here by the
;;; address of its WKWebView (Objective-C objects never move), so a delegate
;;; callback, which gets the WKWebView, finds the Lisp object and its
;;; handlers. Main thread only.

(defclass webview (objc-object)
  ((options :initarg :options :accessor webview-options
            :documentation "MAKE-WEBVIEW's options, with :DELEGATE added.")
   (window :initarg :window :reader webview-window
           :documentation "The WINDOW the webview was made in."))
  (:documentation "A webview made by MAKE-WEBVIEW. WEBVIEW-POINTER is its
WKWebView, which SEND also accepts the webview itself in place of."))

(defun webview-pointer (webview)
  "The WKWebView behind WEBVIEW, for calling WebKit directly with SEND."
  (objc-object-pointer webview))

(defvar *routes* (make-hash-table)
  "WEBVIEW objects by the address of their WKWebView. Main thread only.")

(defun find-webview (webview)
  "The live WEBVIEW object for WEBVIEW (a WEBVIEW or its WKWebView pointer),
or NIL once DESTROY-WEBVIEW has released it."
  (gethash (objc-address webview) *routes*))

(defun route (webview key)
  "The option KEY of WEBVIEW, a WEBVIEW or its WKWebView."
  (let ((object (find-webview webview)))
    (and object (getf (webview-options object) key))))

(defun webviews ()
  "Every webview made by MAKE-WEBVIEW and not yet destroyed."
  (on-main (lambda ()
             (loop for webview being the hash-values of *routes*
                   collect webview))))

(defmethod print-object ((webview webview) stream)
  (print-unreadable-object (webview stream :type t)
    (let ((url (handler-case
                   (on-main (lambda ()
                              (if (find-webview webview)
                                  (let ((url (send webview "URL")))
                                    (if (cffi:null-pointer-p url)
                                        :blank
                                        (lisp-string (send url "absoluteString"))))
                                  :destroyed))
                            :timeout 1)
                 (error () nil))))
      (if (stringp url)
          (format stream "~S" url)
          (format stream "~@[~(~A~) ~]#x~X" url (objc-address webview))))))

(defmethod describe-object ((webview webview) stream)
  (format stream "~&~S is a webview made by MAKE-WEBVIEW.~%" webview)
  (handler-case
      (on-main (lambda ()
                 (let ((object (find-webview webview)))
                   (cond ((null object)
                          (format stream "  It has been destroyed by DESTROY-WEBVIEW.~%"))
                         (t
                          (format stream "  Window: ~S~%" (webview-window webview))
                          (format stream "  Options:~%")
                          (loop for (key value) on (webview-options webview) by #'cddr
                                unless (eq key :delegate)
                                  do (format stream "    ~S ~S~%" key value))
                          (describe-objc (webview-pointer webview) stream)))))
               :timeout 2)
    (error (e) (format stream "  (The main thread could not answer: ~A)~%" e))))
