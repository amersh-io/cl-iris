;;;; Test harness for cl-iris. Run with (asdf:test-system "cl-iris").

(defpackage #:cl-iris/test
  (:use #:cl #:cl-iris/objc #:cl-iris/window)
  (:export #:run!))

(in-package #:cl-iris/test)

(defvar *failures* '())

(defmacro check (name form)
  `(handler-case
       (if ,form
           (format t "~&ok    ~A~%" ,name)
           (progn (push ,name *failures*)
                  (format t "~&FAIL  ~A~%" ,name)))
     (error (e)
       (push ,name *failures*)
       (format t "~&FAIL  ~A: ~A~%" ,name e))))
