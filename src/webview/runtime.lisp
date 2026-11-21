;;;; Loading WebKit; per-webview Lisp functions.

(in-package #:cl-iris/webview)

(cffi:define-foreign-library webkit
  (:darwin "/System/Library/Frameworks/WebKit.framework/WebKit"))

(cffi:use-foreign-library webkit)

(defparameter *message-handler-name* "iris"
  "The name pages post to: window.webkit.messageHandlers.iris.")

;;; Each webview's Lisp functions, keyed by the webview's address. Objective-C
;;; objects never move, so the address is a stable key. Main thread only.

(defvar *routes* (make-hash-table))

(defun route (webview key)
  (getf (gethash (cffi:pointer-address webview) *routes*) key))
