;;;; Where a webview is, and moving through its history.

(in-package #:cl-iris/webview)

(defun webview-url (webview)
  "The URL WEBVIEW is showing, or NIL before it has loaded anything."
  (on-main (lambda () (url-string (send webview "URL")))))

(defun reload (webview)
  "Load WEBVIEW's current page again."
  (on-main (lambda () (send webview "reload" :pointer)))
  nil)

(defun can-go-back-p (webview)
  "True if WEBVIEW has a page to go back to."
  (on-main (lambda () (send webview "canGoBack" :bool))))

(defun can-go-forward-p (webview)
  "True if WEBVIEW has a page to go forward to."
  (on-main (lambda () (send webview "canGoForward" :bool))))

(defun go-back (webview)
  "Go back one page in WEBVIEW's history; returns NIL if there is none."
  (on-main (lambda ()
             (when (send webview "canGoBack" :bool)
               (send webview "goBack" :pointer)
               t))))

(defun go-forward (webview)
  "Go forward one page in WEBVIEW's history; returns NIL if there is none."
  (on-main (lambda ()
             (when (send webview "canGoForward" :bool)
               (send webview "goForward" :pointer)
               t))))
