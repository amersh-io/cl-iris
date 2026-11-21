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

;;; alert(), confirm() and prompt()
;;;
;;; WebKit hands each panel a completion handler that must be called exactly
;;; once. With an :ON-DIALOG handler, Lisp answers at once; without one, an
;;; alert sheet is shown on the webview's window and answers when dismissed.

(defconstant +first-button+ 1000)

(define-block-invoker sheet-ended :void ((response :long)))

(defun copy-block (block)
  (cffi:foreign-funcall "_Block_copy" :pointer block :pointer))

(defun show-panel (webview kind message default finish)
  "Show MESSAGE in an alert sheet on WEBVIEW's window and call FINISH with the
answer once it is dismissed: T or NIL for :CONFIRM, the text or NIL for
:PROMPT. Without a window, answer as if cancelled."
  (let ((window (send webview "window")))
    (if (cffi:null-pointer-p window)
        (funcall finish nil)
        (let ((alert (send (send (find-class* "NSAlert") "alloc") "init"))
              (field nil))
          (send alert "setMessageText:" :pointer (ns-string message) :void)
          (send alert "addButtonWithTitle:" :pointer (ns-string "OK"))
          (unless (eq kind :alert)
            (send alert "addButtonWithTitle:" :pointer (ns-string "Cancel")))
          (when (eq kind :prompt)
            (setf field (send (send (find-class* "NSTextField") "alloc") "initWithFrame:"
                              (:struct ns-rect) (make-rect 0 0 240 24)))
            (send field "setStringValue:" :pointer (ns-string (or default "")) :void)
            (send alert "setAccessoryView:" :pointer field :void)
            (release field))
          (with-block (ended (cffi:callback sheet-ended)
                             (lambda (response)
                               (let ((ok (= response +first-button+)))
                                 (funcall finish
                                          (case kind
                                            (:confirm ok)
                                            (:prompt (and ok (lisp-string (send field "stringValue"))))
                                            (t nil))))))
            (send alert "beginSheetModalForWindow:completionHandler:"
                  :pointer window :pointer ended :void))
          (release alert)))))

(defun run-panel (webview kind message default completion answer)
  "Answer a JavaScript panel of KIND through WebKit's COMPLETION block, once:
from :ON-DIALOG if WEBVIEW has one, else from a sheet. ANSWER calls the
block with a Lisp answer."
  (let ((completion (copy-block completion))
        (done nil))
    (flet ((finish (value)
             (unless done
               (setf done t)
               (unwind-protect (funcall answer completion value)
                 (release-block completion)))))
      (if (route webview :on-dialog)
          (multiple-value-bind (value handled)
              (apply #'call-handler webview :on-dialog "on-dialog" kind message
                     (when (eq kind :prompt) (list default)))
            (finish (and handled value)))
          (handler-case (show-panel webview kind message default #'finish)
            (serious-condition (c)
              (report-error "a JavaScript panel" c)
              (finish nil)))))))

(defun alert-panel (webview message completion)
  (run-panel webview :alert (lisp-string message) nil completion
             (lambda (block value) (declare (ignore value)) (call-block block))))

(defun confirm-panel (webview message completion)
  (run-panel webview :confirm (lisp-string message) nil completion
             (lambda (block value) (call-block block :bool (and value t)))))

(defun prompt-panel (webview prompt default completion)
  (run-panel webview :prompt (lisp-string prompt)
             (unless (cffi:null-pointer-p default) (lisp-string default))
             completion
             (lambda (block value)
               (call-block block :pointer (if (stringp value)
                                              (ns-string value)
                                              (cffi:null-pointer))))))
