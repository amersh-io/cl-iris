;;;; Evaluating JavaScript.

(in-package #:cl-iris/webview)

;;; -evaluateJavaScript:completionHandler: takes a block, made with MAKE-BLOCK:
;;; WebKit keeps its own reference until it has called it, and the Lisp
;;; callback's handle goes away with the last reference.

(define-condition javascript-error (error)
  ((message :initarg :message :reader javascript-error-message))
  (:report (lambda (c stream)
             (format stream "JavaScript error: ~A" (javascript-error-message c)))))

(define-block-invoker js-completion :void ((result :pointer) (error :pointer)))

(defun completion-function (callback)
  (lambda (result error)
    (funcall callback
             (objc->lisp result)
             (unless (cffi:null-pointer-p error)
               (lisp-string (send error "localizedDescription"))))))

(defun eval-js (webview script &key (wait t) callback)
  "Evaluate SCRIPT in WEBVIEW.

With WAIT (the default), block until it finishes and return its value
converted to Lisp, or signal JAVASCRIPT-ERROR. Waiting is not possible on the
main thread, which has to run the script.

Without WAIT, return NIL at once; CALLBACK, if given, is later called on the
main thread with the value and an error message (or NIL)."
  (cond (wait
         (when (main-thread-p)
           (error "EVAL-JS cannot wait on the main thread; pass :WAIT NIL and a :CALLBACK."))
         (let ((done (sb-thread:make-semaphore :name "cl-iris eval-js"))
               (value nil)
               (message nil))
           (eval-js webview script
                    :wait nil
                    :callback (lambda (v m)
                                (setf value v message m)
                                (sb-thread:signal-semaphore done)))
           (sb-thread:wait-on-semaphore done)
           (if message
               (error 'javascript-error :message message)
               value)))
        (t
         (let ((callback (or callback
                             (lambda (value message)
                               (declare (ignore value))
                               (when message (report-error "eval-js" message))))))
           (on-main
            (lambda ()
              (with-block (block (cffi:callback js-completion)
                                 (completion-function callback))
                (send webview "evaluateJavaScript:completionHandler:"
                      :pointer (ns-string script)
                      :pointer block
                      :void)))
            :wait nil))
         nil)))
