;;;; Navigation: deciding whether to follow a link, and hearing pages load.

(in-package #:cl-iris/webview)

(defun url-string (url)
  "The NSURL URL as a Lisp string, or NIL."
  (unless (cffi:null-pointer-p url)
    (lisp-string (send url "absoluteString"))))

(defun call-handler (webview key description &rest arguments)
  "Call WEBVIEW's KEY handler with ARGUMENTS, if it has one. Returns its value
and true, or NIL and NIL when there is no handler or it signalled (reported)."
  (let ((handler (route webview key)))
    (when handler
      (handler-case (values (apply handler arguments) t)
        (serious-condition (c)
          (report-error description c)
          (values nil nil))))))

;;; Deciding

(defconstant +navigation-cancel+ 0)
(defconstant +navigation-allow+ 1)

(defun decide-navigation (webview action decide)
  "Answer the decision block DECIDE for the WKNavigationAction ACTION, once."
  (let ((url (url-string (send (send action "request") "URL"))))
    (multiple-value-bind (allow handled)
        (call-handler webview :on-navigate "on-navigate" url)
      (call-block decide :long (if (or (not handled) allow)
                                   +navigation-allow+
                                   +navigation-cancel+)))))

;;; Loading

(defun page-load (webview event &optional error)
  "Tell WEBVIEW's :ON-PAGE-LOAD handler about EVENT for its current URL."
  (apply #'call-handler webview :on-page-load "on-page-load"
         event (url-string (send webview "URL"))
         (when error (list (lisp-string (send error "localizedDescription"))))))

;;; The web content process

(defun web-process-terminated (webview)
  "WebKit's content process for WEBVIEW died (it crashed, or the system
reclaimed it): call :ON-WEB-PROCESS-TERMINATED, or reload by default."
  (multiple-value-bind (value handled)
      (call-handler webview :on-web-process-terminated "on-web-process-terminated" webview)
    (declare (ignore value))
    (unless (route webview :on-web-process-terminated)
      (send webview "reload" :pointer))
    handled))
