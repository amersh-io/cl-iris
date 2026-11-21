;;;; The user interface WebKit asks its client for: new windows, JavaScript
;;;; panels, file choosers and permissions (WKUIDelegate).

(in-package #:cl-iris/webview)

;;; New windows: window.open() and links with target=_blank

(defun open-externally (url)
  "Open URL with the user's default application for it."
  (send (send (find-class* "NSWorkspace") "sharedWorkspace") "openURL:"
        :pointer (ns-url url) :bool))

(defun new-window-request (webview action)
  "Decide what becomes of a page's request for a new window. Returns a null
pointer: cl-iris never lets WebKit make the window itself."
  (let* ((request (send action "request"))
         (url (url-string (send request "URL"))))
    (multiple-value-bind (choice handled)
        (call-handler webview :on-new-window "on-new-window" url)
      (case (if (route webview :on-new-window) (and handled choice) :here)
        (:here (when url (send webview "loadRequest:" :pointer request :pointer)))
        (:browser (when url (open-externally url)))
        ((nil))
        (t (report-error "on-new-window"
                         (make-condition 'simple-error
                                         :format-control "Expected :HERE, :BROWSER or NIL, got ~S."
                                         :format-arguments (list choice)))))))
  (cffi:null-pointer))
