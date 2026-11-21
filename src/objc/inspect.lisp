;;;; Looking inside the Objective-C runtime from the REPL.

(in-package #:cl-iris/objc)

(defun objc-class-p (object)
  "True if OBJECT (a pointer or OBJC-OBJECT) is a class rather than an instance."
  (let ((pointer (objc-pointer object)))
    (and (not (cffi:null-pointer-p pointer))
         (cffi:foreign-funcall "class_isMetaClass"
                               :pointer (cffi:foreign-funcall "object_getClass"
                                                              :pointer pointer :pointer)
                               :bool))))

(defun objc-class (designator)
  "The class DESIGNATOR names: a class name, a class, or an object (whose
class is returned)."
  (cond ((stringp designator) (find-class* designator))
        ((objc-class-p designator) (objc-pointer designator))
        (t (cffi:foreign-funcall "object_getClass"
                                 :pointer (objc-pointer designator) :pointer))))

(defun objc-class-name (designator)
  "The name of the class DESIGNATOR names (see OBJC-CLASS)."
  (cffi:foreign-funcall "class_getName" :pointer (objc-class designator) :string))

(defun objc-superclasses (designator)
  "The names of the superclasses of the class DESIGNATOR names, nearest first."
  (loop for class = (cffi:foreign-funcall "class_getSuperclass"
                                          :pointer (objc-class designator) :pointer)
          then (cffi:foreign-funcall "class_getSuperclass" :pointer class :pointer)
        until (cffi:null-pointer-p class)
        collect (cffi:foreign-funcall "class_getName" :pointer class :string)))

(defun copied-list (function class reader)
  "Call the runtime's class_copy...List FUNCTION on CLASS and return READER of
each element, freeing the list."
  (cffi:with-foreign-object (count :unsigned-int)
    (let ((list (cffi:foreign-funcall-pointer (cffi:foreign-symbol-pointer function) ()
                                              :pointer class :pointer count :pointer)))
      (unwind-protect
           (loop for i below (cffi:mem-ref count :unsigned-int)
                 collect (funcall reader (cffi:mem-aref list :pointer i)))
        (unless (cffi:null-pointer-p list)
          (cffi:foreign-funcall "free" :pointer list :void))))))

(defun objc-class-methods (designator &key inherited)
  "The selector names of the instance methods the class DESIGNATOR names
defines itself, sorted; with INHERITED, those of its superclasses too."
  (let ((names '()))
    (loop for class = (objc-class designator)
            then (cffi:foreign-funcall "class_getSuperclass" :pointer class :pointer)
          until (cffi:null-pointer-p class)
          do (setf names
                   (nconc (copied-list "class_copyMethodList" class
                                       (lambda (method)
                                         (cffi:foreign-funcall
                                          "sel_getName"
                                          :pointer (cffi:foreign-funcall "method_getName"
                                                                         :pointer method :pointer)
                                          :string)))
                          names))
          while inherited)
    (sort (remove-duplicates names :test #'string=) #'string<)))

(defun objc-class-protocols (designator)
  "The names of the protocols the class DESIGNATOR names adopts itself, sorted."
  (sort (copied-list "class_copyProtocolList" (objc-class designator)
                     (lambda (protocol)
                       (cffi:foreign-funcall "protocol_getName" :pointer protocol :string)))
        #'string<))

(defun objc-description (object)
  "OBJECT's -description, as a Lisp string."
  (lisp-string (send object "description")))

(defmethod describe-object ((object objc-object) stream)
  (format stream "~&~S stands for the Objective-C object at #x~X.~%"
          object (objc-address object))
  (describe-objc (objc-object-pointer object) stream))

(defun describe-objc (object &optional (stream *standard-output*))
  "Print what the runtime knows about OBJECT, a pointer or OBJC-OBJECT: its
class and superclasses, adopted protocols and description."
  (let ((class (objc-class object)))
    (format stream "~&  Class: ~A~{ < ~A~}~%" (objc-class-name class) (objc-superclasses class))
    (let ((protocols (objc-class-protocols class)))
      (when protocols
        (format stream "  Protocols: ~{~A~^, ~}~%" protocols)))
    (unless (objc-class-p object)
      (with-autorelease-pool
        (format stream "  Description: ~A~%" (objc-description object)))))
  (values))
