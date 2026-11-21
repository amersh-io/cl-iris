;;;; Tests of the application's life across more than one loop, each run in
;;;; a child Lisp so that its loops are the child's first.

(in-package #:cl-iris/test)

(defparameter *second-loop-script* "(progn
(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))
(cl-iris:with-application (:activation-policy :accessory)
  (let ((window (cl-iris:make-window :title \"first\")))
    (let ((webview (cl-iris:make-webview window :html \"<title>x</title>\")))
      (sleep 0.3)
      (cl-iris:destroy-webview webview))
    (cl-iris:close-window window)))
(let ((launched nil))
  (sb-thread:make-thread (lambda ()
                           (sleep 3)
                           (when (cl-iris:application-running-p) (cl-iris:stop-application))))
  (cl-iris:run-application :activation-policy :accessory :quit-on-last-window-closed t
                           :on-launch (lambda () (setf launched t)))
  (format t \"~&LAUNCHED ~A~%\" launched)))")

(defparameter *last-window-script* "(progn
(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))
(let ((stopped-by-hand nil))
  (sb-thread:make-thread (lambda ()
                           (sleep 5)
                           (when (cl-iris:application-running-p)
                             (setf stopped-by-hand t)
                             (cl-iris:stop-application))))
  (cl-iris:run-application
   :activation-policy :accessory :quit-on-last-window-closed t
   :on-launch (lambda ()
                (sb-thread:make-thread
                 (lambda ()
                   (let ((window (cl-iris:make-window :title \"only\")))
                     (sleep 0.3)
                     (cl-iris:with-main-thread () (cl-iris/objc:send window \"performClose:\"
                                                                 :pointer (cffi:null-pointer) :void)))))))
  (format t \"~&STOPPED-BY-HAND ~A~%\" stopped-by-hand)))")

(defun lifecycle-checks ()
  (when (selected-p "a second loop")
    (let ((output (run-child-lisp "(asdf:load-system \"cl-iris\")" *second-loop-script*)))
      ;; The loop that closed a window with a webview leaves AppKit's
      ;; last-window check pending; only a close in the new loop may quit it.
      (check "a second loop with quit-on-last-window-closed runs its on-launch"
             (search "LAUNCHED T" output))))
  (when (selected-p "the user closing the last window")
    (let ((output (run-child-lisp "(asdf:load-system \"cl-iris\")" *last-window-script*)))
      (check "the user closing the last window ends a loop that quits on it"
             (search "STOPPED-BY-HAND NIL" output)))))
