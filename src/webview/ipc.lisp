;;;; Messages from pages: posted (one way) and invoked (answered).
;;;;
;;;; Every webview's pages get window.iris:
;;;;
;;;;   iris.post(value)    -> ON-MESSAGE is called with the value; nothing comes back
;;;;   iris.invoke(value)  -> a Promise of what ON-INVOKE returns for the value
;;;;
;;;; Values cross as JSON-like data (see OBJC->LISP and LISP->OBJC).

(in-package #:cl-iris/webview)

(defparameter *invoke-handler-name* "irisInvoke"
  "The name of the answering handler: window.webkit.messageHandlers.irisInvoke.")

(defparameter *bridge-script*
  "(() => {
  const handlers = window.webkit.messageHandlers;
  Object.defineProperty(window, 'iris', {
    value: Object.freeze({
      post: (value) => handlers.iris.postMessage(value),
      invoke: (value) => handlers.irisInvoke.postMessage(value),
    }),
  });
})();"
  "Defines window.iris in every frame of every page.")

(defun receive-message (message)
  (let* ((webview (send message "webView"))
         (handler (route webview :on-message)))
    (when handler
      (let ((*webview* (find-webview webview)))
        (handler-case (funcall handler (objc->lisp (send message "body")))
          (serious-condition (c) (report-error "on-message" c)))))))

;;; Answering an invocation
;;;
;;; WebKit's reply handler must be called exactly once. It is kept (copied)
;;; until then, and only ever called on the main thread.

(defun reply-function (reply)
  "A function of (VALUE &key ERROR) that answers the invocation behind the
reply block REPLY once, from any thread; later calls signal an error."
  (let ((block (cffi:foreign-funcall "_Block_copy" :pointer reply :pointer))
        (lock (sb-thread:make-mutex :name "cl-iris invoke reply"))
        (used nil))
    (lambda (value &key error)
      (sb-thread:with-mutex (lock)
        (when used (error "This invocation was already answered."))
        (setf used t))
      (on-main
       (lambda ()
         (unwind-protect
              (if error
                  (call-block block :pointer (cffi:null-pointer)
                                    :pointer (ns-string (princ-to-string error)))
                  (call-block block :pointer (lisp->objc value)
                                    :pointer (cffi:null-pointer)))
           (release-block block)))
       :wait nil)
      nil)))

(defun receive-invocation (message reply)
  (let* ((webview (send message "webView"))
         (handler (route webview :on-invoke))
         (answer (reply-function reply))
         (*webview* (find-webview webview)))
    (handler-case
        (cond ((null handler)
               (funcall answer nil :error "This webview has no :on-invoke handler."))
              ((route webview :invoke-async)
               (funcall handler (objc->lisp (send message "body")) answer))
              (t
               (funcall answer (funcall handler (objc->lisp (send message "body"))))))
      (serious-condition (c)
        (report-error "on-invoke" c)
        (ignore-errors (funcall answer nil :error (princ-to-string c)))))))
