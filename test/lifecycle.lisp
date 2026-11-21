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

;;; Objects outliving what they stand for. Objective-C reuses the address of a
;;; released object, so a destroyed webview's or a closed window's Lisp object
;;; can share its address with a newer one. Such a stale object is made here
;;; directly, with the newer object's pointer, as reuse would leave it.

(defun stale-object-checks ()
  (with-window (window :title "stale" :width 200 :height 100 :activate nil)
    (let* ((webview (make-webview window :html "<title>t</title>"))
           (stale (make-instance 'webview :pointer (webview-pointer webview)
                                          :window window)))
      (unwind-protect
           (progn
             (check "a stale webview object does not find the newer webview at its address"
                    (null (with-main-thread () (find-webview stale))))
             (check "the newer webview is still found by its own object and its pointer"
                    (and (eq webview (with-main-thread () (find-webview webview)))
                         (eq webview (with-main-thread () (find-webview (webview-pointer webview))))))
             (check "using a stale webview object signals WEBVIEW-DESTROYED"
                    (every (lambda (f)
                             (handler-case (progn (funcall f stale) nil)
                               (webview-destroyed () t)))
                           (list (lambda (w) (eval-js w "1"))
                                 #'webview-url #'reload #'webview-zoom #'webview-bounds
                                 (lambda (w) (load-html w "<p>no</p>"))
                                 (lambda (w) (setf (webview-zoom w) 2))
                                 #'cookies)))
             (check "a stale webview object counts as destroyed"
                    (webview-destroyed-p stale)))
        (destroy-webview webview)))
    (let ((stale (make-instance 'window :pointer (window-pointer window))))
      (check "a stale window object does not find the newer window at its address"
             (null (with-main-thread () (find-window stale))))
      (check "using a stale window object signals WINDOW-CLOSED"
             (handler-case (progn (window-title stale) nil)
               (window-closed () t)))))
  (let* ((window (make-window :title "destroyed" :width 200 :height 100 :activate nil))
         (webview (make-webview window :html "<title>d</title>")))
    (unwind-protect
         (progn
           (destroy-webview webview)
           (check "a destroyed webview counts as destroyed"
                  (webview-destroyed-p webview))
           (check "eval-js on a destroyed webview signals instead of crashing"
                  (handler-case (progn (eval-js webview "1") nil)
                    (webview-destroyed () t)))
           (check "eval-js without waiting on a destroyed webview signals at once"
                  (handler-case (progn (eval-js webview "1" :wait nil) nil)
                    (webview-destroyed () t)))
           (check "destroying a webview twice is harmless"
                  (null (destroy-webview webview))))
      (close-window window))))
