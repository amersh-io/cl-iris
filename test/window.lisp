;;;; Tests for cl-iris/window. Window and webview checks run on a worker
;;;; thread while the main thread sits in RUN-APPLICATION, which is how
;;;; cl-iris is meant to be used.

(in-package #:cl-iris/test)

(defun window-checks ()
  (check "the worker is not the main thread"
         (not (main-thread-p)))
  (check "on-main runs on the main thread"
         (on-main #'main-thread-p))
  (check "on-main returns every value"
         (equal '(1 2) (multiple-value-list (on-main (lambda () (values 1 2))))))
  (check "on-main signals the error again in the caller"
         (handler-case (progn (on-main (lambda () (error "boom"))) nil)
           (error (e) (search "boom" (princ-to-string e)))))
  (check "on-main leaves no handles behind"
         (let ((before (handle-count)))
           (on-main (lambda () 1))
           (on-main (lambda () 2) :wait nil)
           (on-main (lambda () 3))
           (= before (handle-count))))
  (check "errors in queued work reach the error reporter"
         ;; Set globally: the error is reported on the main thread, which does
         ;; not see this thread's bindings.
         (let ((seen nil)
               (old *error-reporter*))
           (setf *error-reporter* (lambda (where c) (declare (ignore where)) (setf seen c)))
           (unwind-protect
                (progn (on-main (lambda () (error "queued boom")) :wait nil)
                       (on-main (lambda () nil))
                       (and seen (search "queued boom" (princ-to-string seen))))
             (setf *error-reporter* old))))
  (check "queued work runs in order"
         (let ((log '()))
           (on-main (lambda () (push :first log)) :wait nil)
           (on-main (lambda () (push :second log)))
           (equal '(:second :first) log)))
  (let ((window (make-window :title "cl-iris test" :width 640 :height 400 :activate nil)))
    (check "a window gets a window number"
           (plusp (window-number window)))
    (check "a window keeps its title"
           (string= "cl-iris test" (window-title window)))
    (check "a window has the content size asked for"
           (equal '(640d0 400d0) (multiple-value-list (window-content-size window))))
    (close-window window)))

(defun application-tests (checks &key (timeout 60))
  "Call each of CHECKS on a worker thread while this, the main thread, runs the
application. Give up and exit the process if it takes more than TIMEOUT seconds."
  (let ((watchdog (sb-thread:make-thread
                   (lambda ()
                     (sleep timeout)
                     (format t "~&FAIL  application tests timed out after ~Ds~%" timeout)
                     (finish-output)
                     (sb-ext:exit :code 3 :abort t))
                   :name "cl-iris test watchdog")))
    (run-application
     ;; Tests run often and must not take focus or add a Dock icon.
     :activation-policy :accessory
     :on-launch (lambda ()
                  (sb-thread:make-thread
                   (lambda ()
                     (unwind-protect (mapc #'funcall checks)
                       (stop-application)))
                   :name "cl-iris test worker")))
    (sb-thread:terminate-thread watchdog)))
