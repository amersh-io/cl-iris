;;;; Autorelease pools.

(in-package #:cl-iris/objc)

;;; Autorelease pools

(defmacro with-autorelease-pool (&body body)
  "Run BODY inside a fresh autorelease pool, draining it on exit."
  (let ((pool (gensym "POOL")))
    `(let ((,pool (%pool-push)))
       (unwind-protect (progn ,@body)
         (%pool-pop ,pool)))))
