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

(defun lifecycle-checks ()
  (when (selected-p "a second loop")
    (let ((output (run-child-lisp "(asdf:load-system \"cl-iris\")" *second-loop-script*)))
      ;; Pinned: the loop that closed a window with a webview leaves AppKit's
      ;; last-window check pending, and the next loop quits on it at once.
      (check "a second loop with quit-on-last-window-closed quits before on-launch (pinned)"
             (search "LAUNCHED NIL" output)))))
