;;;; Tests for cl-iris/objc.

(in-package #:cl-iris/test)

;;; Block invokers used by the tests.

(define-block-invoker add-block :long-long ((a :long-long) (b :long-long)))
(define-block-invoker each-object-block :void ((object :pointer) (index :unsigned-long) (stop :pointer)))
(define-block-invoker plain-block :void ())

(defun wait-for (predicate &key (timeout 5))
  (loop repeat (* timeout 100)
        thereis (funcall predicate)
        do (sleep 0.01)))

(defun block-tests ()
  (let ((before (handle-count)))
    (check "a block calls its Lisp function"
           (with-block (b (cffi:callback add-block) #'+)
             (= 42 (call-block b :long-long 40 :long-long 2 :long-long))))
    (check "a released block frees its handle"
           (= before (handle-count)))
    (check "Foundation calls a block synchronously"
           (let ((seen '()))
             (with-block (b (cffi:callback each-object-block)
                            (lambda (object index stop)
                              (declare (ignore stop))
                              (push (cons index (lisp-string object)) seen)))
               (send (lisp->objc (vector "a" "b" "c")) "enumerateObjectsUsingBlock:"
                     :pointer b :void))
             (equal '((0 . "a") (1 . "b") (2 . "c")) (reverse seen))))
    (check "GCD keeps a block alive and releases it after running it"
           (let ((ran nil))
             (with-block (b (cffi:callback plain-block) (lambda () (setf ran t)))
               (cffi:foreign-funcall "dispatch_async"
                                     :pointer (cffi:foreign-funcall "dispatch_get_global_queue"
                                                                    :long 0 :unsigned-long 0 :pointer)
                                     :pointer b :void))
             (and (wait-for (lambda () ran))
                  (wait-for (lambda () (= before (handle-count)))))))
    (check "an error in a block is reported, not raised into C"
           (let ((seen nil)
                 (old *error-reporter*))
             (setf *error-reporter* (lambda (where c) (declare (ignore where)) (setf seen c)))
             (unwind-protect
                  (with-block (b (cffi:callback add-block)
                                 (lambda (a b) (declare (ignore a b)) (error "block boom")))
                    (and (= 0 (call-block b :long-long 1 :long-long 2 :long-long))
                         seen))
               (setf *error-reporter* old))))))

;;; Methods implemented in Lisp, called from the Objective-C runtime.

(cffi:defcallback add-to :long-long
    ((self :pointer) (cmd :pointer) (a :long-long) (b :long-long))
  (declare (ignore self cmd))
  (+ a b))

(cffi:defcallback greet :pointer
    ((self :pointer) (cmd :pointer) (name :pointer))
  (declare (ignore self cmd))
  (ns-string (format nil "hello, ~A" (lisp-string name))))

(defun make-test-object ()
  (let ((class (ensure-class "CLIrisTestObject" "NSObject")))
    (set-method class "add:to:" (cffi:callback add-to) "q@:qq")
    (set-method class "greet:" (cffi:callback greet) "@@:@")
    (send (send class "alloc") "init")))

(defun objc-tests ()
  (with-autorelease-pool
    (check "find a class by name"
           (not (cffi:null-pointer-p (find-class* "NSObject"))))
    (check "a missing class signals NO-SUCH-CLASS"
           (handler-case (progn (find-class* "CLIrisNoSuchClass") nil)
             (no-such-class (c) (equal "CLIrisNoSuchClass" (objc-error-name c)))))
    (check "a missing protocol signals NO-SUCH-PROTOCOL"
           (handler-case (progn (add-protocol (find-class* "NSObject") "CLIrisNoSuchProtocol") nil)
             (no-such-protocol () t)))
    (check "a missing class is NIL when not required"
           (null (find-class* "CLIrisNoSuchClass" nil)))
    (check "a handle keeps its value until its last owner releases it"
           (let ((h (make-handle :payload)))
             (retain-handle h)
             (release-handle h)
             (and (eq :payload (handle-value h))
                  (progn (release-handle h) t)
                  (not (nth-value 1 (handle-value h))))))
    (check "take-handle forgets a handle at once"
           (let ((h (make-handle :once)))
             (and (eq :once (take-handle h))
                  (not (nth-value 1 (take-handle h))))))
    (check "selectors are interned"
           (cffi:pointer-eq (selector "description") (selector "description")))
    (check "NSString round trip keeps non-ASCII text"
           (string= "héllo, ☃" (lisp-string (ns-string "héllo, ☃"))))
    (check "structs pass by value and come back"
           (let ((rect (send (send (find-class* "NSValue") "valueWithRect:"
                                   (:struct ns-rect) (make-rect 1 2 30 40))
                             "rectValue" (:struct ns-rect))))
             (equal '(1d0 2d0 30d0 40d0)
                    (list (rect-x rect) (rect-y rect) (rect-width rect) (rect-height rect)))))
    (check "retain and release change the reference count"
           (let* ((object (send (send (find-class* "NSObject") "alloc") "init"))
                  (start (retain-count object)))
             (retain object)
             (prog1 (= (1+ start) (retain-count object))
               (release object)
               (release object))))
    (check "Lisp values survive a round trip through Foundation"
           (every (lambda (value) (equalp value (objc->lisp (lisp->objc value))))
                  (list "héllo" 42 -7 2.5d0 t nil :null
                        (vector 1 "two" (vector 3.5d0 :null)))))
    (check "hash tables become dictionaries and back"
           (let ((table (make-hash-table :test 'equal)))
             (setf (gethash "a" table) (vector 1 t))
             (equalp table (objc->lisp (lisp->objc table)))))
    (check "JSON parsed by Foundation converts as JSON"
           (let* ((json (send (ns-string "{\"a\": [1, 2.5, true, false, null, \"x\"]}")
                              "dataUsingEncoding:" :unsigned-long 4))
                  (object (send (find-class* "NSJSONSerialization")
                                "JSONObjectWithData:options:error:"
                                :pointer json :unsigned-long 0 :pointer (cffi:null-pointer)))
                  (value (objc->lisp object)))
             (equalp (vector 1 2.5d0 t nil :null "x") (gethash "a" value))))
    (check "send with an integer return type"
           (= 5 (send (ns-string "hello") "length" :unsigned-long)))
    (let ((object (make-test-object)))
      (check "a run-time class answers its Lisp method"
             (responds-to-p object "add:to:"))
      (check "Lisp callback receives and returns integers"
             (= 42 (send object "add:to:" :long-long 2 :long-long 40 :long-long)))
      (check "Lisp callback receives and returns objects"
             (string= "hello, iris"
                      (lisp-string (send object "greet:" :pointer (ns-string "iris")))))
      (check "ensure-class returns the existing class"
             (cffi:pointer-eq (send object "class")
                              (ensure-class "CLIrisTestObject" "NSObject")))
      (release object))))

;;; Classes declared with DEFINE-OBJC-CLASS

(define-objc-class "CLIrisDeclaredCounter" ()
  (:method "add:to:" :long-long (self (a :long-long) (b :long-long))
    (+ a b))
  (:method "describe:" :pointer (self (name :pointer))
    (ns-string (format nil "<~A>" (lisp-string name))))
  (:method "fail" :int (self)
    (error "method boom")))

(defun declared-class-tests ()
  (with-autorelease-pool
    (let ((object (send (send (find-class* "CLIrisDeclaredCounter") "alloc") "init")))
      (check "a declared class answers its Lisp methods"
             (and (= 5 (send object "add:to:" :long-long 2 :long-long 3 :long-long))
                  (string= "<x>" (lisp-string (send object "describe:" :pointer (ns-string "x"))))))
      (check "a method's error is reported and a zero value returned"
             (let ((seen nil) (old *error-reporter*))
               (setf *error-reporter* (lambda (where c) (declare (ignore where)) (setf seen c)))
               (unwind-protect (and (= 0 (send object "fail" :int)) seen)
                 (setf *error-reporter* old))))
      (check "method type encodings follow the CFFI types"
             (string= "q@:qq"
                      (cffi:foreign-string-to-lisp
                       (cffi:foreign-funcall "method_getTypeEncoding"
                                             :pointer (cffi:foreign-funcall
                                                       "class_getInstanceMethod"
                                                       :pointer (find-class* "CLIrisDeclaredCounter")
                                                       :pointer (selector "add:to:")
                                                       :pointer)
                                             :pointer))))
      (release object))))

;;; Uncaught Objective-C exceptions, checked in a child process since they
;;; end it.

(defun run-child-lisp (&rest forms)
  "Run FORMS, strings read in the child, in a fresh Lisp with cl-iris loadable;
return its output and exit code."
  (let ((root (asdf:system-source-directory "cl-iris")))
    (multiple-value-bind (output error-output code)
        (uiop:run-program
         (append (list sb-ext:*runtime-pathname* "--non-interactive" "--no-userinit"
                       "--load" (namestring (merge-pathnames ".qlot/setup.lisp" root))
                       "--eval" (format nil "(asdf:load-asd ~S)"
                                        (namestring (merge-pathnames "cl-iris.asd" root))))
                 (loop for form in forms append (list "--eval" form)))
         :directory root :output :string :error-output :string :ignore-error-status t)
      (values (concatenate 'string output error-output) code))))

(defun exception-tests ()
  (multiple-value-bind (output code)
      (run-child-lisp "(asdf:load-system \"cl-iris/objc\")"
                      "(cl-iris/objc:install-exception-reporter)"
                      "(defun index-out-of-range ()
                         (cl-iris/objc:send (cl-iris/objc:send (cl-iris/objc:find-class* \"NSArray\") \"array\")
                                            \"objectAtIndex:\" :unsigned-long 5))"
                      "(index-out-of-range)")
    (check "an uncaught exception ends the process"
           (/= 0 code))
    (check "an uncaught exception is reported with its name and reason"
           (search "uncaught Objective-C exception NSRangeException" output))
    (check "an uncaught exception is reported with the Lisp backtrace"
           (search "INDEX-OUT-OF-RANGE" output))))

;;; Saved images. A process that saves itself with SAVE-LISP-AND-DIE and is
;;; started again must find no stale foreign addresses: classes, selectors,
;;; block descriptors and declared classes all have to come back.

(defun run-saved-core (core &rest forms)
  (multiple-value-bind (output error-output code)
      (uiop:run-program
       (append (list sb-ext:*runtime-pathname* "--core" (namestring core)
                     "--non-interactive" "--no-userinit")
               (loop for form in forms append (list "--eval" form)))
       :output :string :error-output :string :ignore-error-status t)
    (values (concatenate 'string output error-output) code)))

(defparameter *after-restart-forms*
  '("(in-package :cl-iris/webview)"
    "(format t \"~&STRING ~A~%\" (with-autorelease-pool (lisp-string (ns-string \"after restart\"))))"
    "(format t \"~&DELEGATE ~A~%\" (not (null (find-class* \"CLIrisWebViewDelegate\" nil))))"
    ;; dispatch_async copies the block, which reads its descriptor.
    "(let ((done (sb-thread:make-semaphore)))
       (with-block (b (cffi:callback js-completion)
                      (lambda (value error)
                        (declare (ignore value error))
                        (sb-thread:signal-semaphore done)))
         (cffi:foreign-funcall \"dispatch_async\"
                               :pointer (cffi:foreign-funcall \"dispatch_get_global_queue\"
                                                              :long 0 :unsigned-long 0 :pointer)
                               :pointer b :void))
       (when (sb-thread:wait-on-semaphore done :timeout 5)
         (format t \"~&BLOCK CALLED~%\")))"
    "(let ((result nil))
       (run-application
        :activation-policy :accessory
        :on-launch (lambda ()
                     (sb-thread:make-thread
                      (lambda ()
                        (unwind-protect
                             (let* ((window (make-window :activate nil :width 200 :height 100))
                                    (webview (make-webview window)))
                               (setf result (eval-js webview \"6 * 7\"))
                               (destroy-webview webview)
                               (close-window window))
                          (stop-application))))))
       (format t \"~&EVAL ~A~%\" result))"))

(defun saved-image-tests ()
  (uiop:with-temporary-file (:pathname core :type "core" :keep nil)
    (multiple-value-bind (output code)
        (run-child-lisp "(asdf:load-system \"cl-iris/webview\")"
                        ;; Make a block first, so foreign caches are filled
                        ;; when the image is saved.
                        "(cl-iris/objc:with-block (b (cffi:callback cl-iris/webview::js-completion)
                                                   (lambda (v e) (declare (ignore v e))))
                           b)"
                        (format nil "(sb-ext:save-lisp-and-die ~S)" (namestring core)))
      (declare (ignore output))
      (check "an image with cl-iris loaded can be saved"
             (and (zerop code) (probe-file core))))
    (multiple-value-bind (output code)
        (apply #'run-saved-core core *after-restart-forms*)
      (check "a restarted image still converts strings"
             (search "STRING after restart" output))
      (check "a restarted image recreates declared classes"
             (search "DELEGATE T" output))
      (check "a restarted image builds and calls blocks"
             (search "BLOCK CALLED" output))
      (check "a restarted image opens a window and runs JavaScript"
             (and (zerop code) (search "EVAL 42" output))))))
