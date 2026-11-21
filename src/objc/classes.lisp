;;;; Defining classes at run time.

(in-package #:cl-iris/objc)

;;; Defining classes at run time

(defun ensure-class (name superclass)
  "Return the class NAME, creating and registering it as a subclass of
SUPERCLASS (a class name) when it does not exist yet."
  (or (find-class* name nil)
      (let ((class (%allocate-class-pair (find-class* superclass) name 0)))
        (when (cffi:null-pointer-p class)
          (error 'class-definition-error :name name))
        (%register-class-pair class)
        class)))

(defun set-method (class selector imp types)
  "Install IMP (a CFFI callback pointer) as the implementation of SELECTOR on
CLASS, replacing any implementation it already has. TYPES is the Objective-C
type encoding of the method, e.g. \"q@:qq\".

IMP receives the receiver and the selector before the method's own arguments."
  (%replace-method class (selector selector) imp types)
  class)

(defun add-protocol (class name &key (errorp t))
  "Declare that CLASS conforms to the protocol NAME. Adding it twice is harmless.

Some framework protocols are only declared in headers and never registered
with the runtime (WebKit's WKScriptMessageHandler, for one); for those, pass
ERRORP NIL to carry on without the declaration. Returns CLASS, or NIL when
the protocol was not found."
  (let ((protocol (%get-protocol name)))
    (cond ((not (cffi:null-pointer-p protocol))
           (%add-protocol class protocol)
           class)
          (errorp (error 'no-such-protocol :name name))
          (t nil))))

;;; Declaring classes with methods written in Lisp

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun error-return-value (type)
    "The form a callback returns after an error, for its CFFI return TYPE."
    (case type
      ((:void :bool) nil)
      (:pointer '(cffi:null-pointer))
      ((:double) 0d0)
      ((:float) 0f0)
      (t 0))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun type-encoding (type)
    "The Objective-C type encoding of the CFFI TYPE, as used in method types."
    (cond ((equal type '(:struct ns-rect)) "{CGRect={CGPoint=dd}{CGSize=dd}}")
          ((equal type '(:struct ns-point)) "{CGPoint=dd}")
          ((equal type '(:struct ns-size)) "{CGSize=dd}")
          (t (ecase type
               (:void "v") (:pointer "@") (:bool "B")
               (:char "c") (:unsigned-char "C") (:short "s") (:unsigned-short "S")
               (:int "i") (:unsigned-int "I")
               ((:long :long-long :int64) "q") ((:unsigned-long :unsigned-long-long :uint64) "Q")
               (:float "f") (:double "d"))))))

(eval-when (:compile-toplevel :load-toplevel :execute)
  (defun method-encoding (return-type argument-types)
    (format nil "~A@:~{~A~}" (type-encoding return-type)
            (mapcar #'type-encoding argument-types))))

(defvar *class-installers* '()
  "Functions that (re)create the classes declared with DEFINE-OBJC-CLASS, in
the order they were declared. Run again when a saved image starts, since the
Objective-C runtime keeps nothing from the process that saved it.")

(defun register-class-installer (name installer)
  (setf *class-installers*
        (append (remove name *class-installers* :key #'car :test #'string=)
                (list (cons name installer))))
  (funcall installer))

(defun reinstall-classes ()
  (dolist (entry *class-installers*)
    (handler-case (funcall (cdr entry))
      (serious-condition (c) (report-error (format nil "recreating class ~A" (car entry)) c)))))

(pushnew 'reinstall-classes sb-ext:*init-hooks*)

(defmacro define-objc-class (name (&key (superclass "NSObject") protocols) &body methods)
  "Declare the Objective-C class NAME, a subclass of SUPERCLASS, with METHODS
written in Lisp. Each method is

  (:method SELECTOR RETURN-TYPE (SELF (ARG TYPE)*) BODY...)

with CFFI types. SELF is bound to the receiver. The class is created if
needed and every method installed whenever the form is evaluated, so
evaluating it again replaces the methods of a live class. Each method body
is also an ordinary Lisp function, named \"<class> <selector>\" in the
current package, so redefining that function changes the method as well.

An error in a method is handed to REPORT-ERROR and a zero value returned.
PROTOCOLS not registered with the runtime are skipped. Returns the class."
  (let ((specs
          (loop for (keyword selector return-type (self . arguments) . body) in methods
                do (assert (eq keyword :method) () "Expected (:method ...), got ~S." keyword)
                collect (list selector return-type self arguments body
                              (intern (format nil "~A ~A" name selector))
                              (intern (format nil "~A ~A imp" name selector))))))
    `(progn
       ;; NOTINLINE: without it SBCL trusts the type it derived for the method
       ;; function in this file, and a redefinition returning another type
       ;; would be rejected at the call.
       ,@(loop for (nil return-type self arguments body function) in specs
               collect `(declaim (notinline ,function))
               collect `(defun ,function (,self ,@(mapcar #'first arguments))
                          (declare (ignorable ,self))
                          ,@body))
       ,@(loop for (selector return-type self arguments nil function imp) in specs
               collect (let ((cmd (gensym "CMD")))
                         `(cffi:defcallback ,imp ,return-type
                              ((,self :pointer) (,cmd :pointer) ,@arguments)
                            (declare (ignore ,cmd))
                            (handler-case (,function ,self ,@(mapcar #'first arguments))
                              (serious-condition (c)
                                (report-error ,(format nil "-[~A ~A]" name selector) c)
                                ,(error-return-value return-type))))))
       (register-class-installer
        ,name
        (lambda ()
          (let ((class (ensure-class ,name ,superclass)))
            (dolist (protocol ',protocols)
              (add-protocol class protocol :errorp nil))
            ,@(loop for (selector return-type nil arguments nil nil imp) in specs
                    collect `(set-method class ,selector (cffi:callback ,imp)
                                         ,(method-encoding return-type
                                                           (mapcar #'second arguments))))
            class)))
       (find-class* ,name))))
