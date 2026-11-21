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
    (check "a missing class is NIL when not required"
           (null (find-class* "CLIrisNoSuchClass" nil)))
    (check "selectors are interned"
           (cffi:pointer-eq (selector "description") (selector "description")))
    (check "NSString round trip keeps non-ASCII text"
           (string= "héllo, ☃" (lisp-string (ns-string "héllo, ☃"))))
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
