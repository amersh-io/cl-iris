;;;; Integer handles for Lisp objects that the Objective-C side refers to.
;;;;
;;;; The garbage collector may move Lisp objects, so their addresses must never
;;;; reach C. Instead a Lisp object is registered under a small integer, and
;;;; only that integer is stored in C memory: a callback's context pointer, a
;;;; block's captured word. Each handle counts its owners and is forgotten when
;;;; the last one releases it.

(in-package #:cl-iris/objc)

(defvar *handles* (make-hash-table))
(defvar *handles-lock* (sb-thread:make-mutex :name "cl-iris handles"))
(defvar *next-handle* 0)

(defun make-handle (value)
  "Register VALUE and return its handle, an integer with one owner."
  (sb-thread:with-mutex (*handles-lock*)
    (let ((id (incf *next-handle*)))
      (setf (gethash id *handles*) (cons value 1))
      id)))

(defun handle-value (handle)
  "Return the value registered under HANDLE and true, or NIL and NIL once the
handle has been released."
  (sb-thread:with-mutex (*handles-lock*)
    (let ((entry (gethash handle *handles*)))
      (if entry
          (values (car entry) t)
          (values nil nil)))))

(defun retain-handle (handle)
  "Add an owner to HANDLE."
  (sb-thread:with-mutex (*handles-lock*)
    (let ((entry (gethash handle *handles*)))
      (when entry (incf (cdr entry)))
      handle)))

(defun release-handle (handle)
  "Remove an owner from HANDLE, forgetting it when none is left."
  (sb-thread:with-mutex (*handles-lock*)
    (let ((entry (gethash handle *handles*)))
      (when (and entry (<= (decf (cdr entry)) 0))
        (remhash handle *handles*))
      nil)))

(defun take-handle (handle)
  "Forget HANDLE whatever its owners, returning its value and whether it was
still registered. For one-shot uses where exactly one party ever takes it."
  (sb-thread:with-mutex (*handles-lock*)
    (let ((entry (gethash handle *handles*)))
      (remhash handle *handles*)
      (values (car entry) (and entry t)))))

(defun handle-count ()
  "The number of live handles; useful to check that nothing leaks."
  (sb-thread:with-mutex (*handles-lock*)
    (hash-table-count *handles*)))
