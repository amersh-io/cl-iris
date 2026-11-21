;;;; NSString <-> Lisp strings.

(in-package #:cl-iris/objc)

;;; Strings

(defun ns-string (string)
  "Return an autoreleased NSString holding the Lisp STRING."
  (send (find-class* "NSString") "stringWithUTF8String:"
        :string string))

(defun lisp-string (ns-string)
  "Return the contents of NS-STRING as a Lisp string."
  (cffi:foreign-string-to-lisp (send ns-string "UTF8String")
                               :encoding :utf-8))
