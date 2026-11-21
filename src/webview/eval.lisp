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

(defparameter *dropped-message*
  "WebKit released the completion handler without calling it")

(defun make-completion-block (callback)
  "A block for -evaluateJavaScript:completionHandler: that calls CALLBACK with
the value and an error message, or with NIL and *DROPPED-MESSAGE* if WebKit
lets it go uncalled (as when the web content process dies)."
  (make-block (cffi:callback js-completion) (completion-function callback)
              :on-drop (lambda () (funcall callback nil *dropped-message*))))

(defun evaluate (webview script callback)
  "On the main thread: start evaluating SCRIPT, calling CALLBACK with the
value and an error message (or NIL) when it finishes."
  (let ((block (make-completion-block callback)))
    (unwind-protect
         (send webview "evaluateJavaScript:completionHandler:"
               :pointer (ns-string script)
               :pointer block
               :void)
      (release-block block))))

(defun eval-js (webview script &key (wait t) callback timeout)
  "Evaluate SCRIPT in WEBVIEW.

With WAIT (the default), block until it finishes and return its value
converted to Lisp (see OBJC->LISP), or signal JAVASCRIPT-ERROR; give up with
MAIN-THREAD-TIMEOUT after TIMEOUT seconds, if given. Waiting is not possible
on the main thread, which has to run the script.

Without WAIT, return NIL at once; CALLBACK, if given, is later called on the
main thread with the value and an error message (or NIL)."
  (cond (wait
         (when (main-thread-p)
           (error "EVAL-JS cannot wait on the main thread; pass :WAIT NIL and a :CALLBACK."))
         (on-main-deferred
          (lambda (reply fail)
            (evaluate webview script
                      (lambda (value message)
                        (if message
                            (funcall fail (make-condition 'javascript-error :message message))
                            (funcall reply value)))))
          :timeout timeout))
        (t
         (let ((callback (or callback
                             (lambda (value message)
                               (declare (ignore value))
                               (when message (report-error "eval-js" message))))))
           (on-main (lambda () (evaluate webview script callback)) :wait nil))
         nil)))
