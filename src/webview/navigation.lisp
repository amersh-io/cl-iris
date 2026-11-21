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
