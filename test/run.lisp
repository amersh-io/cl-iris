(in-package #:cl-iris/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '())
  (objc-tests)
  (block-tests)
  (main-thread-wait-checks)
  (application-tests (list #'window-checks #'webview-checks))
  (when *failures*
    (error "~D cl-iris test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
