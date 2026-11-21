;;;; Evaluating JavaScript.

(in-package #:cl-iris/webview)

;;; Evaluating JavaScript
;;;
;;; -evaluateJavaScript:completionHandler: takes a block. We build one by hand
;;; in foreign memory, marked global so the runtime neither copies nor frees
;;; it. Its last word holds the integer id of the Lisp function to call.
;;;
;;;   0 isa   8 flags, reserved   16 invoke   24 descriptor   32 id
;;;   40 descriptor: reserved, size

(defconstant +block-is-global+ (ash 1 28))
(defconstant +block-size+ 40)

(define-condition javascript-error (error)
  ((message :initarg :message :reader javascript-error-message))
  (:report (lambda (c stream)
             (format stream "JavaScript error: ~A" (javascript-error-message c)))))

(cffi:defcallback js-completion :void
    ((block :pointer) (result :pointer) (error :pointer))
  (let ((function (take-handle (cffi:mem-ref block :int64 32))))
    ;; WebKit releases the block after calling it, so free it only later.
    (on-main (lambda () (cffi:foreign-free block)) :wait nil)
    (when function
      (handler-case
          (funcall function
                   (objc->lisp result)
                   (unless (cffi:null-pointer-p error)
                     (lisp-string (send error "localizedDescription"))))
        (serious-condition (c) (report "eval-js callback" c))))))

(defun make-completion-block (function)
  (let ((block (cffi:foreign-alloc :uint8 :count (+ +block-size+ 16))))
    (setf (cffi:mem-ref block :pointer 0) (cffi:foreign-symbol-pointer "_NSConcreteGlobalBlock")
          (cffi:mem-ref block :int32 8) +block-is-global+
          (cffi:mem-ref block :int32 12) 0
          (cffi:mem-ref block :pointer 16) (cffi:callback js-completion)
          (cffi:mem-ref block :pointer 24) (cffi:inc-pointer block +block-size+)
          (cffi:mem-ref block :int64 32) (make-handle function)
          (cffi:mem-ref block :uint64 40) 0
          (cffi:mem-ref block :uint64 48) +block-size+)
    block))

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
                               (when message (report "eval-js" message))))))
           (on-main
            (lambda ()
              (send webview "evaluateJavaScript:completionHandler:"
                    :pointer (ns-string script)
                    :pointer (make-completion-block callback)
                    :void))
            :wait nil))
         nil)))
