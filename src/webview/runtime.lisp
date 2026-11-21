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

(defgeneric webview-window (webview)
  (:documentation "The WINDOW WEBVIEW was made in."))

(defclass webview (objc-object)
  ((options :initarg :options :accessor webview-options
            :documentation "MAKE-WEBVIEW's options, with :DELEGATE added.")
   (window :initarg :window :reader webview-window
           :documentation "The WINDOW the webview was made in.")
   (destroyed :initform nil :accessor %webview-destroyed
              :documentation "Set by DESTROY-WEBVIEW, so other threads can
refuse a destroyed webview without asking the main thread."))
  (:documentation "A webview made by MAKE-WEBVIEW. WEBVIEW-POINTER is its
WKWebView, which SEND also accepts the webview itself in place of."))

(defun webview-pointer (webview)
  "The WKWebView behind WEBVIEW, for calling WebKit directly with SEND."
  (objc-object-pointer webview))

(defvar *routes* (make-hash-table)
  "WEBVIEW objects by the address of their WKWebView. Main thread only.")

(defun find-webview (webview)
  "The live WEBVIEW object for WEBVIEW (a WEBVIEW or its WKWebView pointer),
or NIL once DESTROY-WEBVIEW has released it. A WEBVIEW object is live only
while it is the one registered at its address: WebKit may reuse the address
of a destroyed webview for a new one."
  (let ((object (gethash (objc-address webview) *routes*)))
    (and object
         (or (cffi:pointerp webview) (eq object webview))
         object)))

(define-condition webview-destroyed (error)
  ((webview :initarg :webview :reader webview-destroyed-webview))
  (:documentation "A webview released by DESTROY-WEBVIEW was used again;
WEBVIEW-DESTROYED-WEBVIEW is the webview.")
  (:report "The webview has been destroyed with DESTROY-WEBVIEW and can no longer be used."))

(defun check-not-destroyed (webview)
  "Signal WEBVIEW-DESTROYED at once, on any thread, if WEBVIEW is a webview
object DESTROY-WEBVIEW has released."
  (when (and (typep webview 'webview) (%webview-destroyed webview))
    (error 'webview-destroyed :webview webview)))

(defun live-webview (webview)
  "On the main thread: the live WEBVIEW object for WEBVIEW, or signal
WEBVIEW-DESTROYED. A message to a released WKWebView would crash the process."
  (or (find-webview webview)
      (error 'webview-destroyed :webview webview)))

(defun on-webview (webview function &rest options)
  "Run FUNCTION on the main thread, as ON-MAIN does with OPTIONS, after
checking that WEBVIEW has not been destroyed (see LIVE-WEBVIEW)."
  (apply #'on-main (lambda ()
                     (live-webview webview)
                     (funcall function))
         options))

(defun webview-destroyed-p (webview)
  "True once DESTROY-WEBVIEW has released WEBVIEW."
  (not (on-main (lambda () (find-webview webview)))))

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
