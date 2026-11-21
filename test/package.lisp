;;;; Test harness for cl-iris. Run with (asdf:test-system "cl-iris").

(defpackage #:cl-iris/test
  (:use #:cl #:cl-iris/objc #:cl-iris/window #:cl-iris/webview)
  (:export #:run!))

(in-package #:cl-iris/test)

(defvar *failures* '())

(defvar *only* nil
  "When a string, only the checks whose names contain it (ignoring case) run.
RUN! takes it from :ONLY or the CL_IRIS_TEST_ONLY environment variable.")

(defvar *skipped* 0)

(defun selected-p (name)
  (or (null *only*) (search *only* name :test #'char-equal)))

(defmacro check (name form)
  "Evaluate FORM as the check NAME: report ok, or FAIL when it returns false
or signals. Skipped, without evaluating FORM, when NAME does not match *ONLY*."
  (let ((n (gensym "NAME")))
    `(let ((,n ,name))
       (if (selected-p ,n)
           (handler-case
               (if ,form
                   (format t "~&ok    ~A~%" ,n)
                   (progn (push ,n *failures*)
                          (format t "~&FAIL  ~A~%" ,n)))
             (error (e)
               (push ,n *failures*)
               (format t "~&FAIL  ~A: ~A~%" ,n e)))
           (incf *skipped*)))))
