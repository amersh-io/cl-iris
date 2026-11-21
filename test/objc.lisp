;;;; Tests for cl-iris/objc.

(in-package #:cl-iris/test)

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
      (send object "release"))))
