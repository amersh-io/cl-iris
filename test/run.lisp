(in-package #:cl-iris/test)

(defun run! (&key (only (sb-ext:posix-getenv "CL_IRIS_TEST_ONLY")))
  "Run every test, or with ONLY (a string) the checks whose names contain it;
signal an error if any of them fails."
  (setf *failures* '()
        *skipped* 0
        *only* (and only (plusp (length only)) only))
  (objc-tests)
  (block-tests)
  (declared-class-tests)
  (exception-tests)
  (saved-image-tests)
  (main-thread-wait-checks)
  (package-checks)
  (documentation-checks)
  (with-application-checks)
  (example-checks)
  (lifecycle-checks)
  (application-tests (list #'window-checks #'live-redefinition-checks #'webview-checks)
                     :timeout 300)
  (when *only*
    (format t "~&~D check~:P skipped: not matching ~S~%" *skipped* *only*))
  (when *failures*
    (error "~D cl-iris test~:P failed: ~{~A~^, ~}"
           (length *failures*) (reverse *failures*)))
  t)
