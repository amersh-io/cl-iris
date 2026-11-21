;;;; Converting between Objective-C objects and Lisp values.
;;;;
;;;; The mapping follows JSON, which is what most values crossing into a
;;;; webview are:
;;;;
;;;;   Objective-C               Lisp
;;;;   nil                       NIL
;;;;   NSNull                    :NULL
;;;;   @YES / @NO                T / NIL       (:FALSE also converts to @NO)
;;;;   NSString                  string
;;;;   NSNumber (integer)        integer
;;;;   NSNumber (floating)       double-float, or an integer when integral
;;;;   NSArray                   simple-vector (a non-empty list also converts)
;;;;   NSDictionary              EQUAL hash table
;;;;   anything else             the object pointer, unchanged
;;;;
;;;; Integral floating point numbers become integers because JavaScript has
;;;; only doubles: 42 arrives from a page as 42.0.

(in-package #:cl-iris/objc)

(defun cf-boolean (name)
  (cffi:mem-ref (cffi:foreign-symbol-pointer name) :pointer))

(defun ns-true () (cf-boolean "kCFBooleanTrue"))
(defun ns-false () (cf-boolean "kCFBooleanFalse"))

(defun integral-double (d)
  (if (and (< (abs d) #.(expt 2d0 53)) (= d (ftruncate d)))
      (truncate d)
      d))

(defun number->lisp (number)
  (let ((type (char (cffi:foreign-string-to-lisp (send number "objCType")) 0)))
    (case type
      ((#\f #\d) (integral-double (send number "doubleValue" :double)))
      (#\Q (send number "unsignedLongLongValue" :unsigned-long-long))
      (t (send number "longLongValue" :long-long)))))

(defun objc->lisp (object)
  "Convert OBJECT, a Foundation value, to Lisp as described above."
  (cond ((cffi:null-pointer-p object) nil)
        ((cffi:pointer-eq object (ns-true)) t)
        ((cffi:pointer-eq object (ns-false)) nil)
        ((kind-of-p object "NSNull") :null)
        ((kind-of-p object "NSString") (lisp-string object))
        ((kind-of-p object "NSNumber") (number->lisp object))
        ((kind-of-p object "NSArray")
         (let ((count (send object "count" :unsigned-long)))
           (let ((vector (make-array count)))
             (dotimes (i count vector)
               (setf (svref vector i)
                     (objc->lisp (send object "objectAtIndex:" :unsigned-long i)))))))
        ((kind-of-p object "NSDictionary")
         (let* ((table (make-hash-table :test 'equal))
                (keys (send object "allKeys")))
           (dotimes (i (send keys "count" :unsigned-long) table)
             (let ((key (send keys "objectAtIndex:" :unsigned-long i)))
               (setf (gethash (objc->lisp key) table)
                     (objc->lisp (send object "objectForKey:" :pointer key)))))))
        (t object)))

(defun lisp->objc (value)
  "Convert VALUE to an autoreleased Foundation object as described above."
  (etypecase value
    (null (ns-false))
    ((eql t) (ns-true))
    ((eql :false) (ns-false))
    ((eql :null) (send (find-class* "NSNull") "null"))
    (string (ns-string value))
    ((signed-byte 64)
     (send (find-class* "NSNumber") "numberWithLongLong:" :long-long value))
    (real
     (send (find-class* "NSNumber") "numberWithDouble:" :double (float value 1d0)))
    ((or vector cons)
     (let ((array (send (find-class* "NSMutableArray") "array")))
       (map nil (lambda (element)
                  (send array "addObject:" :pointer (lisp->objc element) :void))
            value)
       array))
    (hash-table
     (let ((dictionary (send (find-class* "NSMutableDictionary") "dictionary")))
       (maphash (lambda (key element)
                  (send dictionary "setObject:forKey:"
                        :pointer (lisp->objc element)
                        :pointer (lisp->objc key)
                        :void))
                value)
       dictionary))
    (sb-sys:system-area-pointer value)))
