;;;; Objective-C values to Lisp.

(in-package #:cl-iris/webview)

;;; Objective-C values to Lisp

(defun objc->lisp (object)
  "Strings and numbers become Lisp strings and numbers (booleans become 1
and 0); null becomes NIL; anything else becomes its description."
  (cond ((or (cffi:null-pointer-p object) (kind-of-p object "NSNull")) nil)
        ((kind-of-p object "NSString") (lisp-string object))
        ((kind-of-p object "NSNumber")
         (let ((d (send object "doubleValue" :double)))
           (if (and (< (abs d) 1d15) (= d (ftruncate d))) (truncate d) d)))
        (t (lisp-string (send object "description")))))

(defun report (where condition)
  (format *error-output* "~&;; cl-iris: error in ~A: ~A~%" where condition))
