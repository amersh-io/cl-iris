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
    (check "a window's title can be changed"
           (progn (setf (window-title window) "renamed")
                  (string= "renamed" (window-title window))))
    (check "a window can be resized"
           (progn (resize-window window 500 300)
                  (equal '(500d0 300d0) (multiple-value-list (window-content-size window)))))
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

(defun main-thread-wait-checks ()
  "Checks of waiting on the main thread around the loop's life. Called on the
main thread, outside any application."
  (check "waiting signals APPLICATION-NOT-RUNNING before the loop runs"
         (let ((thread (sb-thread:make-thread
                        (lambda ()
                          (handler-case (progn (on-main (lambda () 1)) :ran)
                            (application-not-running () :refused))))))
           (eq :refused (sb-thread:join-thread thread))))
  (let ((before (handle-count))
        (stranded nil)
        (never-ran t))
    (run-application
     :activation-policy :accessory
     :on-launch
     (lambda ()
       (setf stranded
             (sb-thread:make-thread
              (lambda ()
                (handler-case
                    (progn (on-main-deferred (lambda (reply fail)
                                               (declare (ignore reply fail))))
                           :replied)
                  (application-stopped () :woken)))))
       (sb-thread:make-thread
        (lambda ()
          (check "a timeout withdraws work the main thread has not started"
                 (progn
                   (on-main (lambda () (sleep 0.5)) :wait nil)
                   (handler-case (progn (on-main (lambda () (setf never-ran nil)) :timeout 0.1)
                                        nil)
                     (main-thread-timeout () (on-main (lambda () t))))))
          (check "withdrawn work never runs"
                 never-ran)
          (check "on-main-deferred returns what the main thread replies later"
                 (equal '(:a :b)
                        (multiple-value-list
                         (on-main-deferred
                          (lambda (reply fail)
                            (declare (ignore fail))
                            (on-main (lambda () (funcall reply :a :b)) :wait nil))))))
          (check "on-main-deferred signals what the main thread fails with"
                 (handler-case (progn (on-main-deferred
                                       (lambda (reply fail)
                                         (declare (ignore reply))
                                         (funcall fail (make-condition 'simple-error
                                                                       :format-control "deferred boom"))))
                                      nil)
                   (error (e) (search "deferred boom" (princ-to-string e)))))
          (sleep 0.2)
          (stop-application)))))
    (check "the loop's end wakes a stranded waiter"
           (eq :woken (sb-thread:join-thread stranded)))
    (check "stopping twice is harmless"
           (null (stop-application)))
    (check "waiting leaves no handles behind"
           (= before (handle-count)))))

;;; Redefining code while the application runs

(define-objc-class "CLIrisLiveTarget" ()
  (:method "value" :int (self) 1))

(defun live-redefinition-checks ()
  (let ((object (on-main (lambda ()
                           (send (send (find-class* "CLIrisLiveTarget") "alloc") "init")))))
    (flet ((value () (on-main (lambda () (send object "value" :int)))))
      (check "a live object answers its declared method"
             (= 1 (value)))
      (check "redefining a method's Lisp function changes the live object"
             (let ((name (intern "CLIrisLiveTarget value" :cl-iris/test)))
               (setf (fdefinition name) (lambda (self) (declare (ignore self)) 2))
               (= 2 (value))))
      (check "evaluating the declaration again replaces the method"
             (progn
               (eval '(define-objc-class "CLIrisLiveTarget" ()
                       (:method "value" :int (self) 3)))
               (= 3 (value))))
      (on-main (lambda () (release object))))))
