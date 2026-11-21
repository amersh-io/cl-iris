(in-package #:cl-iris/test)

(defun run! ()
  "Run every test; signal an error if any of them fails."
  (setf *failures* '())
  (objc-tests)
  (block-tests)
  (declared-class-tests)
  (exception-tests)
  (saved-image-tests)
  (main-thread-wait-checks)
  (package-checks)
  (documentation-checks)
  (with-application-checks)
  (application-tests (list #'window-checks #'live-redefinition-checks #'webview-checks)
                     :timeout 300)
  (when *failures*
    (error "~D cl-iris test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
