;;;; The user interface WebKit asks its client for: new windows, JavaScript
;;;; panels, file choosers and permissions (WKUIDelegate).

(in-package #:cl-iris/webview)

(defun match-parent-opacity (sheet window)
  "Give SHEET the opacity of the WINDOW it will be attached to, so a sheet on
a window kept out of sight stays out of sight too."
  (send sheet "setAlphaValue:" :double (send window "alphaValue" :double) :void))

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
            (match-parent-opacity (send alert "window") window)
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

;;; <input type=file>
;;;
;;; WebKit asks for files with a completion handler, called once with an
;;; array of file URLs, or nil if the user cancelled.

(defun file-url-array (paths)
  (let ((array (send (find-class* "NSMutableArray") "array")))
    (dolist (path paths array)
      (send array "addObject:"
            :pointer (send (find-class* "NSURL") "fileURLWithPath:"
                           :pointer (ns-string (namestring path)))
            :void))))

(defun url-paths (array)
  (loop for i below (send array "count" :unsigned-long)
        collect (lisp-string (send (send array "objectAtIndex:" :unsigned-long i) "path"))))

(defun show-open-panel (webview multiple directories finish)
  (let ((window (send webview "window")))
    (if (cffi:null-pointer-p window)
        (funcall finish nil)
        (let ((panel (send (find-class* "NSOpenPanel") "openPanel")))
          (send panel "setAllowsMultipleSelection:" :bool multiple :void)
          (send panel "setCanChooseDirectories:" :bool directories :void)
          (send panel "setCanChooseFiles:" :bool t :void)
          (with-block (ended (cffi:callback sheet-ended)
                             (lambda (response)
                               (funcall finish (when (= response 1)
                                                 (url-paths (send panel "URLs"))))))
            (match-parent-opacity panel window)
            (send panel "beginSheetModalForWindow:completionHandler:"
                  :pointer window :pointer ended :void))))))

(defun open-panel (webview parameters completion)
  "Answer a page's request for files: from :ON-FILE-DIALOG, else an open panel."
  (let ((completion (copy-block completion))
        (multiple (send parameters "allowsMultipleSelection" :bool))
        (directories (send parameters "allowsDirectories" :bool))
        (done nil))
    (flet ((finish (paths)
             (unless done
               (setf done t)
               (unwind-protect
                    (call-block completion :pointer (if paths
                                                        (file-url-array paths)
                                                        (cffi:null-pointer)))
                 (release-block completion)))))
      (if (route webview :on-file-dialog)
          (multiple-value-bind (paths handled)
              (call-handler webview :on-file-dialog "on-file-dialog"
                            :multiple multiple :directories directories)
            (finish (and handled paths)))
          (handler-case (show-open-panel webview multiple directories #'finish)
            (serious-condition (c)
              (report-error "a file panel" c)
              (finish nil)))))))

;;; Camera and microphone (macOS 12 and later)

(defparameter *capture-kinds* '((0 . :camera) (1 . :microphone) (2 . :camera-and-microphone)))
(defparameter *permission-decisions* '((:prompt . 0) (:grant . 1) (:deny . 2)))

(defun origin-string (origin)
  "The WKSecurityOrigin ORIGIN as \"scheme://host[:port]\", or NIL."
  (unless (cffi:null-pointer-p origin)
    (let ((port (send origin "port" :long)))
      (format nil "~A://~A~@[:~D~]"
              (lisp-string (send origin "protocol"))
              (lisp-string (send origin "host"))
              (and (plusp port) port)))))

(defun media-capture-permission (webview origin type decide)
  "Answer a page's request for the camera or microphone through the decision
block DECIDE, once: from :ON-PERMISSION, else let WebKit prompt as usual."
  (multiple-value-bind (choice handled)
      (call-handler webview :on-permission "on-permission"
                    (cdr (assoc type *capture-kinds*)) (origin-string origin))
    (call-block decide :long (or (and handled (cdr (assoc choice *permission-decisions*)))
                                 (cdr (assoc :prompt *permission-decisions*))))))
