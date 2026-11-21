;;;; Blocks: Objective-C closures, built from Lisp functions.
;;;;
;;;; Many Cocoa and WebKit APIs take a block. A block is a small struct whose
;;;; first words are an isa pointer, flags and an invoke function; Clang lays
;;;; out what it captures after those. We lay one out by hand in foreign
;;;; memory, capturing a single word: the handle of the Lisp function to call.
;;;;
;;;;   0 isa   8 flags   12 reserved   16 invoke   24 descriptor   32 handle
;;;;
;;;; The literal is built as a stack block and immediately copied with
;;;; _Block_copy, so the block we hand out is an ordinary heap block that the
;;;; runtime reference-counts. Our copy helper retains the handle for every
;;;; heap copy and the dispose helper releases it, so the Lisp function lives
;;;; exactly as long as some block still refers to it, however long the API we
;;;; pass it to keeps it.

(in-package #:cl-iris/objc)

(defconstant +block-has-copy-dispose+ (ash 1 25))
(defconstant +block-has-signature+ (ash 1 30))
(defconstant +block-literal-size+ 40)
(defconstant +block-handle-offset+ 32)
(defconstant +block-invoke-offset+ 16)

(cffi:defcallback block-copy-helper :void ((destination :pointer) (source :pointer))
  (declare (ignore source))
  (retain-handle (cffi:mem-ref destination :int64 +block-handle-offset+)))

(cffi:defcallback block-dispose-helper :void ((block :pointer))
  (release-handle (cffi:mem-ref block :int64 +block-handle-offset+)))

;;; Descriptors are shared by every block with the same signature. They live in
;;; malloc'd memory, which an image saved with SAVE-LISP-AND-DIE does not keep,
;;; so the cache is emptied when such an image starts.

(defvar *descriptors* (make-hash-table :test 'equal))
(defvar *descriptors-lock* (sb-thread:make-mutex :name "cl-iris block descriptors"))

(defun forget-foreign-caches ()
  (clrhash *descriptors*))

(pushnew 'forget-foreign-caches sb-ext:*init-hooks*)

(defun block-descriptor (signature)
  (sb-thread:with-mutex (*descriptors-lock*)
    (or (gethash signature *descriptors*)
        (setf (gethash signature *descriptors*)
              (let ((descriptor (cffi:foreign-alloc :pointer :count 5)))
                (setf (cffi:mem-aref descriptor :uint64 0) 0
                      (cffi:mem-aref descriptor :uint64 1) +block-literal-size+
                      (cffi:mem-aref descriptor :pointer 2) (cffi:callback block-copy-helper)
                      (cffi:mem-aref descriptor :pointer 3) (cffi:callback block-dispose-helper)
                      (cffi:mem-aref descriptor :pointer 4)
                      (if signature
                          (cffi:foreign-string-alloc signature)
                          (cffi:null-pointer)))
                descriptor)))))

(defun make-block (invoker function &key signature)
  "Return a new heap block that calls FUNCTION through INVOKER, a callback
defined with DEFINE-BLOCK-INVOKER. SIGNATURE is the block's Objective-C type
encoding, e.g. \"v24@?0@8@16\"; most APIs do not need it.

The caller owns one reference: pass the block on, then RELEASE-BLOCK it (or
use WITH-BLOCK). APIs that keep the block take their own reference."
  (let ((handle (make-handle function))
        (literal (cffi:foreign-alloc :uint8 :count +block-literal-size+)))
    (unwind-protect
         (progn
           (setf (cffi:mem-ref literal :pointer 0)
                 (cffi:foreign-symbol-pointer "_NSConcreteStackBlock")
                 (cffi:mem-ref literal :int32 8)
                 (logior +block-has-copy-dispose+
                         (if signature +block-has-signature+ 0))
                 (cffi:mem-ref literal :int32 12) 0
                 (cffi:mem-ref literal :pointer +block-invoke-offset+) invoker
                 (cffi:mem-ref literal :pointer 24) (block-descriptor signature)
                 (cffi:mem-ref literal :int64 +block-handle-offset+) handle)
           ;; The copy helper gives the heap block its own hold on the handle.
           (cffi:foreign-funcall "_Block_copy" :pointer literal :pointer))
      (cffi:foreign-free literal)
      (release-handle handle))))

(defun release-block (block)
  "Drop the caller's reference to BLOCK."
  (cffi:foreign-funcall "_Block_release" :pointer block :void))

(defmacro with-block ((var invoker function &rest options) &body body)
  "Bind VAR to a block made with MAKE-BLOCK for the extent of BODY."
  `(let ((,var (make-block ,invoker ,function ,@options)))
     (unwind-protect (progn ,@body)
       (release-block ,var))))

(defun block-function (block)
  "The Lisp function a block made by MAKE-BLOCK calls."
  (values (handle-value (cffi:mem-ref block :int64 +block-handle-offset+))))

(defun error-return-value (type)
  (case type
    ((:void :bool) nil)
    (:pointer '(cffi:null-pointer))
    ((:double) 0d0)
    ((:float) 0f0)
    (t 0)))

(defmacro define-block-invoker (name return-type (&rest arguments))
  "Define NAME as a CFFI callback to use as the invoke function of blocks
whose arguments are ARGUMENTS, a list of (name type) as in CFFI:DEFCALLBACK.
It calls the block's Lisp function with those arguments and returns its
value. An error is handed to REPORT-ERROR and a zero value is returned."
  (let ((block (gensym "BLOCK")))
    `(cffi:defcallback ,name ,return-type ((,block :pointer) ,@arguments)
       (handler-case (funcall (block-function ,block) ,@(mapcar #'first arguments))
         (serious-condition (c)
           (report-error ,(format nil "a block calling ~(~A~)" name) c)
           ,(error-return-value return-type))))))

(defmacro call-block (block &rest arguments)
  "Call BLOCK, any Objective-C block, with ARGUMENTS given as CFFI type/value
pairs, optionally followed by the return type (default :VOID)."
  (let ((b (gensym "BLOCK")))
    `(let ((,b ,block))
       (cffi:foreign-funcall-pointer
        (cffi:mem-ref ,b :pointer ,+block-invoke-offset+) ()
        :pointer ,b
        ,@arguments
        ,@(when (evenp (length arguments)) '(:void))))))
