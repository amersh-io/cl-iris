;;;; Tests for cl-iris/window. Window and webview checks run on a worker
;;;; thread while the main thread sits in RUN-APPLICATION, which is how
;;;; cl-iris is meant to be used.

(in-package #:cl-iris/test)

(defun eventually (predicate &key (timeout 5))
  "Poll PREDICATE until it returns true or TIMEOUT seconds pass; for changes
AppKit animates."
  (loop repeat (* timeout 20)
        thereis (funcall predicate)
        do (sleep 0.05)))

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
           (equal '(640d0 400d0) (window-size window)))
    (check "a window's title can be changed"
           (progn (setf (window-title window) "renamed")
                  (string= "renamed" (window-title window))))
    (check "a window can be resized"
           (progn (setf (window-size window) '(500 300))
                  (equal '(500d0 300d0) (window-size window))))
    (check "a window can be moved"
           (progn (setf (window-position window) '(120 140))
                  (equal '(120d0 140d0) (window-position window))))
    (check "a frame can be set as a whole and read back"
           (let ((frame (window-frame window)))
             (setf (window-frame window) (list 100 120 520 360))
             (prog1 (equal '(100d0 120d0 520d0 360d0) (window-frame window))
               (setf (window-frame window) frame))))
    (check "a size must be a list of two numbers"
           (handler-case (progn (setf (window-size window) 500) nil)
             (error () t)))
    (check "the frame includes the title bar"
           (destructuring-bind (x y width height) (window-frame window)
             (declare (ignore x y))
             (and (= width 500) (> height 300))))
    (check "centering moves a window into the middle of its screen"
           (progn (center-window window)
                  (let ((x (first (window-position window))))
                    (multiple-value-bind (sx sy screen-width)
                        (on-main (lambda ()
                                   (let ((frame (send (send window "screen") "visibleFrame"
                                                      (:struct ns-rect))))
                                     (values (rect-x frame) (rect-y frame) (rect-width frame)))))
                      (declare (ignore sy))
                      (< (abs (- (+ x 250) (+ sx (/ screen-width 2)))) 2)))))
    (check "a window keeps the minimum and maximum sizes it is given"
           (progn (setf (window-min-size window) '(300 200)
                        (window-max-size window) '(900 700))
                  (and (equal '(300d0 200d0) (window-min-size window))
                       (equal '(900d0 700d0) (window-max-size window)))))
    (check "a new window has the default style"
           (equal '(:titled :closable :miniaturizable :resizable) (window-style window)))
    (check "a window can be made fixed in size"
           (progn (setf (window-resizable-p window) nil)
                  (and (not (window-resizable-p window))
                       (not (member :resizable (window-style window))))))
    (check "a window without decorations has no title bar"
           (progn (setf (window-decorated-p window) nil)
                  (and (not (window-decorated-p window))
                       (= (fourth (window-frame window)) (second (window-size window))))))
    (check "a window starts at the normal level"
           (eq :normal (window-level window)))
    (check "a window can be kept on top"
           (progn (setf (window-level window) :floating)
                  (prog1 (eq :floating (window-level window))
                    (setf (window-level window) :normal))))
    (close-window window))
  (let ((window (make-window :title "visibility" :activate nil))
        (other (make-window :title "other" :activate nil)))
    (check "a hidden window is not visible"
           (progn (hide-window window)
                  (not (window-visible-p window))))
    (check "a shown window is visible again"
           (progn (show-window window)
                  (window-visible-p window)))
    ;; Without activating, which tests must not do, the application has no
    ;; key window; what focusing does then is bring the window to the front.
    (check "focusing a window brings it in front of the application's others"
           (flet ((front () (on-main (lambda ()
                                       (cffi:pointer-address
                                        (send (send (cl-iris/window::app) "orderedWindows")
                                              "firstObject"))))))
             (focus-window other :activate nil)
             (let ((before (front)))
               (focus-window window :activate nil)
               (and (= before (objc-address other))
                    (= (front) (objc-address window))))))
    (close-window other)
    (close-window window))
  (check "hex colors are read as sRGB components"
         (and (equal '(1d0 0d0 0d0 1d0) (color-components "#f00"))
              (equal '(0d0 0d0 1d0 1d0) (color-components "#0000ff"))
              (equal '(1d0 1d0 1d0 0d0) (color-components "#ffffff00"))))
  (check "list colors get an alpha of 1 when they have none"
         (equal '(0.5d0 0.25d0 0d0 1d0) (color-components '(0.5 0.25 0))))
  (check "malformed colors are refused"
         (every (lambda (color)
                  (handler-case (progn (color-components color) nil)
                    (error () t)))
                (list "#12" "#gggggg" '(2 0 0) "red" 42)))
  (let ((window (make-window :title "colors" :width 300 :height 200 :activate nil)))
    (check "a window's opacity can be changed"
           (let ((before (window-alpha window)))
             (setf (window-alpha window) 0.5)
             (prog1 (= 0.5d0 (window-alpha window))
               (setf (window-alpha window) before))))
    (check "a window's background color can be set and read back"
           (progn (setf (window-background-color window) "#336699")
                  (every (lambda (a b) (< (abs (- a b)) 1d-3))
                         (window-background-color window)
                         (color-components "#336699"))))
    (check "a window can be made transparent"
           (progn (setf (window-transparent-p window) t)
                  (and (window-transparent-p window)
                       (zerop (fourth (window-background-color window))))))
    (check "a transparent window can be made opaque again"
           (progn (setf (window-transparent-p window) nil)
                  (not (window-transparent-p window))))
    (close-window window))
  (let ((window (make-window :title "shadow and mouse" :width 200 :height 100 :activate nil)))
    (check "a window's shadow can be turned off and on"
           (and (window-shadow-p window)
                (progn (setf (window-shadow-p window) nil) (not (window-shadow-p window)))
                (progn (setf (window-shadow-p window) t) (window-shadow-p window))))
    (check "a window can let mouse events pass through"
           (and (not (window-ignores-mouse-p window))
                (progn (setf (window-ignores-mouse-p window) t)
                       (window-ignores-mouse-p window))))
    (check "a window's content can be kept out of screen captures"
           (and (not (window-content-protected-p window))
                (progn (setf (window-content-protected-p window) t)
                       (window-content-protected-p window))))
    (check "a window's content can be held to an aspect ratio"
           (and (null (window-aspect-ratio window))
                (progn (setf (window-aspect-ratio window) 16/9)
                       (< (abs (- (window-aspect-ratio window) 16/9)) 1d-6))
                (progn (setf (window-aspect-ratio window) nil)
                       (null (window-aspect-ratio window)))))
    (check "a window can be shown on every Space"
           (and (not (window-on-all-spaces-p window))
                (progn (setf (window-on-all-spaces-p window) t)
                       (window-on-all-spaces-p window))
                (progn (setf (window-on-all-spaces-p window) nil)
                       (not (window-on-all-spaces-p window)))))
    (close-window window))
  (let ((window (make-window :title "appearance" :width 300 :height 200 :activate nil)))
    (check "a window can be drawn dark or light"
           (progn (setf (window-appearance window) :dark)
                  (and (eq :dark (window-appearance window))
                       (progn (setf (window-appearance window) :light)
                              (eq :light (window-appearance window))))))
    (check "a window can follow the system's appearance again"
           (progn (setf (window-appearance window) :system)
                  (member (window-appearance window) '(:light :dark))))
    (check "the title text can be hidden"
           (progn (setf (window-title-visible-p window) nil)
                  (not (window-title-visible-p window))))
    (check "the title bar can be made transparent over full-size content"
           (progn (setf (window-style window) (adjoin :full-size-content-view (window-style window))
                        (window-titlebar-transparent-p window) t)
                  (and (window-titlebar-transparent-p window)
                       ;; The content now fills the frame, under the title bar.
                       (= (fourth (window-frame window)) (second (window-size window))))))
    (close-window window))
  (let ((window (make-window :title "built" :width 320 :height 240 :activate nil
                             :resizable nil :min-size '(100 80) :max-size '(640 480)
                             :level :floating :alpha 0.9 :background-color "#102030"
                             :appearance :dark :title-visible nil
                             :titlebar-transparent t :center t)))
    (check "make-window applies every option it is given"
           (and (not (window-resizable-p window))
                (equal '(100d0 80d0) (window-min-size window))
                (equal '(640d0 480d0) (window-max-size window))
                (eq :floating (window-level window))
                (< (abs (- 0.9d0 (window-alpha window))) 1d-6)
                (eq :dark (window-appearance window))
                (not (window-title-visible-p window))
                (window-titlebar-transparent-p window)
                (window-visible-p window)))
    (close-window window))
  (let ((window (make-window :title "hidden" :visible nil :decorations nil)))
    (check "make-window :visible NIL waits for show-window"
           (and (not (window-visible-p window))
                (progn (show-window window) (window-visible-p window))))
    (check "make-window :decorations NIL leaves out the title bar"
           (not (window-decorated-p window)))
    (close-window window))
  (screen-checks)
  (application-checks)
  (theme-checks)
  (window-event-checks)
  (macro-checks)
  (timer-checks)
  (default-menu-checks)
  (menu-checks)
  (let ((window (make-window :title "minimize and zoom" :width 300 :height 200 :activate nil)))
    (check "a window can be minimized and restored"
           (progn (minimize-window window)
                  (and (eventually (lambda () (window-minimized-p window)))
                       (progn (restore-window window)
                              (eventually (lambda () (not (window-minimized-p window))))))))
    (check "a window can be maximized and brought back"
           (progn (setf (window-maximized-p window) t)
                  (and (eventually (lambda () (window-maximized-p window)))
                       (progn (setf (window-maximized-p window) nil)
                              (eventually (lambda () (not (window-maximized-p window))))))))
    ;; Entering full screen takes over a Space on the screen, which a test
    ;; run must not do; only the resting state is checked.
    (check "a new window is not in full screen"
           (not (window-fullscreen-p window)))
    (close-window window))
  (let ((window (make-window :title "borderless" :style '() :activate nil)))
    (check "make-window :style NIL opens a borderless window"
           (null (window-style window)))
    (close-window window))
  (check "make-window refuses bad arguments before touching AppKit"
         (every (lambda (arguments)
                  (handler-case (progn (apply #'make-window :activate nil arguments) nil)
                    (error () t)))
                '((:width -5) (:height 0) (:title 42) (:min-size (100)) (:max-size "big"))))
  (check "an unknown style keyword is refused"
         (handler-case (progn (make-window :style '(:wobbly) :activate nil) nil)
           (error (e) (search "WOBBLY" (princ-to-string e))))))

(defun timer-checks ()
  (let ((before (handle-count)))
    (check "run-after calls its function once on the main thread, later"
           (let* ((start (get-internal-real-time))
                  (fired '()))
             (run-after 0.2 (lambda () (push (list (main-thread-p) (get-internal-real-time)) fired)))
             (and (eventually (lambda () fired))
                  (progn (sleep 0.3) (= 1 (length fired)))
                  (first (first fired))
                  (>= (- (second (first fired)) start)
                      (* 0.15 internal-time-units-per-second)))))
    (check "a cancelled timer never fires"
           (let ((fired nil))
             (cancel-timer (run-after 0.1 (lambda () (setf fired t))))
             (sleep 0.3)
             (not fired)))
    (check "run-every fires repeatedly until cancelled"
           (let* ((count 0)
                  (timer (run-every 0.05 (lambda () (incf count)))))
             (and (eventually (lambda () (>= count 3)))
                  (progn (cancel-timer timer)
                         (sleep 0.2)
                         (let ((after count))
                           (sleep 0.2)
                           (= after count))))))
    (check "a repeating timer can cancel itself"
           (let* ((count 0) (timer nil))
             (setf timer (run-every 0.05 (lambda ()
                                           (when (= 2 (incf count))
                                             (cancel-timer timer)))))
             (sleep 0.4)
             (and (= 2 count) (timer-cancelled-p timer))))
    (check "an error in a repeating timer is reported and the timer goes on"
           (let* ((count 0) (reported nil)
                  (old *error-reporter*))
             (setf *error-reporter* (lambda (where c) (declare (ignore c)) (setf reported where)))
             (unwind-protect
                  (let ((timer (run-every 0.05 (lambda ()
                                                 (incf count)
                                                 (error "timer boom")))))
                    (prog1 (and (eventually (lambda () (>= count 2)))
                                (equal "a timer" reported))
                      (cancel-timer timer)
                      (sleep 0.15)))
               (setf *error-reporter* old))))
    (check "finished and cancelled timers leave no handles behind"
           (eventually (lambda () (= before (handle-count)))))))

(defun default-menu-checks ()
  "Checks of the menu bar RUN-APPLICATION installs; run before anything
replaces it."
  (flet ((item-is (path key selector)
           (let ((item (apply #'find-menu-item path)))
             (and item
                  (on-main (lambda ()
                             (and (string= key (lisp-string (send item "keyEquivalent")))
                                  (cffi:pointer-eq (selector selector) (send item "action")))))))))
    (check "the default menu bar has an Edit menu for copy and paste"
           (and (item-is '("Edit" "Copy") "c" "copy:")
                (item-is '("Edit" "Paste") "v" "paste:")
                (item-is '("Edit" "Cut") "x" "cut:")
                (item-is '("Edit" "Select All") "a" "selectAll:")
                (item-is '("Edit" "Undo") "z" "undo:")))
    (check "the default application menu quits through the quit request"
           (item-is (list (application-name) (format nil "Quit ~A" (application-name)))
                    "q" "terminate:"))
    (check "windows are not merged into tabs unless asked for"
           (not (on-main (lambda ()
                           (send (find-class* "NSWindow") "allowsAutomaticWindowTabbing" :bool)))))
    (check "the Window menu is the application's windows menu"
           (on-main (lambda ()
                      (string= "Window" (lisp-string (send (send (cl-iris/window::app) "windowsMenu")
                                                           "title"))))))))

(defun menu-checks ()
  (let ((chosen '()))
    (set-menu-bar
     `((:menu "App" (:item "Quit" :key "q" :selector "terminate:"))
       (:menu "Tools"
        (:item "Run" :key "r" :modifiers (:command :shift)
               :action ,(lambda () (push :run chosen)))
        (:item "Disabled" :action ,(lambda () (push :disabled chosen)) :enabled nil)
        :separator
        (:item "Option" :checked t :action ,(lambda () nil))
        (:menu "More" (:item "Deep" :action ,(lambda () (push :deep chosen)))))))
    (check "a menu item is found by its path of titles"
           (and (find-menu-item "Tools" "Run")
                (find-menu-item "Tools" "More" "Deep")
                (null (find-menu-item "Tools" "Missing"))))
    (check "a menu item has the key equivalent and modifiers it was given"
           (let ((item (find-menu-item "Tools" "Run")))
             (on-main (lambda ()
                        (and (string= "r" (lisp-string (send item "keyEquivalent")))
                             (= (logior (ash 1 17) (ash 1 20))
                                (send item "keyEquivalentModifierMask" :unsigned-long)))))))
    (check "choosing a menu item calls its Lisp action"
           (progn (perform-menu-item (find-menu-item "Tools" "Run"))
                  (perform-menu-item (find-menu-item "Tools" "More" "Deep"))
                  (equal '(:deep :run) chosen)))
    (check "an item made disabled is disabled, and can be enabled"
           (let ((item (find-menu-item "Tools" "Disabled")))
             (and (not (menu-item-enabled-p item))
                  (progn (setf (menu-item-enabled-p item) t)
                         (menu-item-enabled-p item)))))
    (check "an item can be checked and unchecked"
           (let ((item (find-menu-item "Tools" "Option")))
             (and (menu-item-checked-p item)
                  (progn (setf (menu-item-checked-p item) nil)
                         (not (menu-item-checked-p item))))))
    (check "a selector item is sent along the responder chain"
           (on-main (lambda ()
                      (let ((item (find-menu-item "App" "Quit")))
                        (and (cffi:null-pointer-p (send item "target"))
                             (cffi:pointer-eq (selector "terminate:") (send item "action")))))))
    (check "a malformed menu is refused and the menu bar kept"
           (and (handler-case (progn (set-menu-bar '((:menu "Bad" (:thing "x")))) nil)
                  (error () t))
                (find-menu-item "Tools" "Run")
                (progn (perform-menu-item (find-menu-item "Tools" "Run"))
                       (equal '(:run :deep :run) chosen))))
    (check "replacing the menu bar forgets the old Lisp actions"
           (progn (set-menu-bar '((:menu "App")))
                  (zerop (on-main (lambda () (hash-table-count cl-iris/window::*menu-actions*))))))))

(defun application-checks ()
  (check "the Dock icon can carry a badge"
         (progn (setf (dock-badge) "3")
                (prog1 (equal "3" (dock-badge))
                  (setf (dock-badge) nil))))
  (check "a cleared badge reads back as NIL"
         (null (dock-badge)))
  (check "asking for attention gives a request that can be cancelled"
         (let ((request (request-user-attention)))
           (and (or (null request) (integerp request))
                (progn (when request (cancel-user-attention request)) t))))
  (let ((window (make-window :title "hide" :width 200 :height 100 :activate nil)))
    (check "hiding the application hides its windows"
           (progn (hide-application)
                  (and (eventually #'application-hidden-p)
                       (not (window-visible-p window)))))
    (check "unhiding the application shows them again"
           (progn (unhide-application)
                  (and (eventually (lambda () (not (application-hidden-p))))
                       (window-visible-p window))))
    (close-window window)))

(defun theme-checks ()
  (check "the system appearance is light or dark"
         (member (system-appearance) '(:light :dark)))
  (let ((seen '()))
    (setf (theme-change-handler) (lambda (appearance) (push appearance seen)))
    (unwind-protect
         (check "a change of the system's appearance is reported"
                (progn
                  ;; Deliver it to the observer as the notification center
                  ;; would; posting the real notification would reach every
                  ;; application on the machine.
                  (on-main (lambda ()
                             (send cl-iris/window::*theme-observer* "themeChanged:"
                                   :pointer (cffi:null-pointer) :void)))
                  (and (eventually (lambda () seen))
                       (eq (first seen) (system-appearance)))))
      (setf (theme-change-handler) nil))))

(defun screen-checks ()
  (let ((screens (screens)))
    (check "there is at least one screen, described in full"
           (and screens
                (every (lambda (screen)
                         (and (stringp (getf screen :name))
                              (= 4 (length (getf screen :frame)))
                              (= 4 (length (getf screen :visible-frame)))
                              (>= (getf screen :scale-factor) 1)))
                       screens)))
    (check "the main screen is one of the screens"
           (member (getf (main-screen) :frame) screens
                   :key (lambda (screen) (getf screen :frame)) :test #'equal))
    (let ((window (make-window :title "screen" :width 200 :height 100 :activate nil)))
      (check "a window knows its screen and scale factor"
             (let ((screen (window-screen window)))
               (and screen
                    (= (window-scale-factor window) (getf screen :scale-factor)))))
      (close-window window))))

(defun package-checks ()
  (check "the cl-iris package exports the window and webview layers' symbols"
         (every (lambda (symbol)
                  (multiple-value-bind (found status)
                      (find-symbol (symbol-name symbol) "CL-IRIS")
                    (and (eq found symbol) (eq status :external))))
                (list 'make-window 'with-application 'window-size
                      'make-webview 'eval-js 'with-webview)))
  (check "the cl-iris package leaves the Objective-C layer out"
         (not (eq :external (nth-value 1 (find-symbol "SEND" "CL-IRIS"))))))

(defun macro-checks ()
  (let ((kept nil))
    (with-window (window :title "with-window" :activate nil)
      (setf kept window)
      (check "with-window binds an open window"
             (not (window-closed-p window))))
    (check "with-window closes its window on the way out"
           (window-closed-p kept)))
  (let ((kept nil))
    (ignore-errors
     (with-window (window :title "unwound" :activate nil)
       (setf kept window)
       (error "leaving")))
    (check "with-window closes its window when the body signals"
           (and kept (window-closed-p kept))))
  (check "with-main-thread runs its body on the main thread and returns its values"
         (equal '(t 2) (multiple-value-list (with-main-thread () (values (main-thread-p) 2)))))
  (check "with-main-thread :wait nil queues the body"
         (let ((ran nil))
           (with-main-thread (:wait nil) (setf ran t))
           (with-main-thread ())
           ran)))

(defun with-application-checks ()
  "WITH-APPLICATION owns the main thread, so it is checked in a child Lisp."
  (multiple-value-bind (output code)
      (run-child-lisp "(asdf:load-system \"cl-iris/window\")"
                      "(in-package :cl-iris/window)"
                      "(format t \"~&VALUES ~S~%\"
                         (multiple-value-list
                          (with-application (:activation-policy :accessory)
                            (values (main-thread-p) (application-running-p)))))"
                      "(format t \"~&CAUGHT ~A~%\"
                         (handler-case (with-application (:activation-policy :accessory)
                                         (error \"from the body\"))
                           (error (e) e)))"
                      "(format t \"~&RUNNING ~S~%\" (application-running-p))")
    (check "with-application runs its body off the main thread while the loop runs"
           (and (eql 0 code) (search "VALUES (NIL T)" output)))
    (check "with-application signals the body's error in the caller"
           (search "CAUGHT from the body" output))
    (check "with-application stops the loop when the body is done"
           (search "RUNNING NIL" output))))

(defun window-event-checks ()
  (let* ((events '())
         (allow-close nil)
         (handed '())
         (window (make-window :title "events" :width 300 :height 200 :activate nil
                              :on-event (lambda (window event &rest arguments)
                                          (push window handed)
                                          (push (cons event arguments) events))
                              :on-close-request (lambda (window)
                                                  (push window handed)
                                                  allow-close))))
    (flet ((seen (event) (find event events :key #'car))
           (post (selector)
             ;; Deliver a notification to the delegate as AppKit would.
             (on-main (lambda ()
                        (send (send window "delegate") selector
                              :pointer (send (find-class* "NSNotification")
                                             "notificationWithName:object:"
                                             :pointer (ns-string "test") :pointer window)
                              :void)))))
      (check "resizing a window reports :resized with the new size"
             (progn (setf (window-size window) '(320 210))
                    (equal '(:resized 320d0 210d0) (seen :resized))))
      (check "moving a window reports :moved with the new position"
             (progn (setf (window-position window) '(150 160))
                    (equal '(:moved 150d0 160d0) (seen :moved))))
      (check "handlers are given the WINDOW object, not its NSWindow"
             (and handed (every (lambda (w) (eq w window)) handed)))
      (check "gaining and losing focus are reported"
             (progn (post "windowDidBecomeKey:")
                    (post "windowDidResignKey:")
                    (and (seen :focused) (seen :unfocused))))
      (check "minimizing and restoring are reported"
             (progn (minimize-window window)
                    (and (eventually (lambda () (seen :minimized)))
                         (progn (restore-window window)
                                (eventually (lambda () (seen :restored)))))))
      (check "a close request the handler refuses leaves the window open"
             (progn (on-main (lambda () (send window "performClose:" :pointer (cffi:null-pointer) :void)))
                    (and (window-visible-p window)
                         (not (window-closed-p window))
                         (not (seen :closed)))))
      (check "a close request the handler allows closes the window"
             (progn (setf allow-close t)
                    (on-main (lambda () (send window "performClose:" :pointer (cffi:null-pointer) :void)))
                    (and (window-closed-p window)
                         (seen :closed))))
      (check "close-window after the user closed a window only releases it"
             (progn (close-window window)
                    (= 1 (count :closed events :key #'car))))
      (check "closing a window twice is harmless"
             (null (close-window window)))))
  (let ((window (make-window :title "listed" :activate nil)))
    (check "a new window is among the windows"
           (member window (windows)))
    (check "a window is a WINDOW object that prints its title and number"
           (and (typep window 'window)
                (search "\"listed\" #" (prin1-to-string window))))
    (check "window-pointer is the NSWindow, and find-window maps it back"
           (and (cffi:pointerp (window-pointer window))
                (eq window (find-window (window-pointer window)))
                (string= "NSWindow" (lisp-string (send (send window "class") "description")))))
    (close-window window))
  (let* ((closed nil)
         (window (make-window :title "closed by lisp" :activate nil
                              :on-event (lambda (window event &rest arguments)
                                          (declare (ignore window arguments))
                                          (when (eq event :closed) (setf closed t))))))
    (close-window window)
    (check "close-window reports :closed"
           closed)
    (check "a window closed by close-window counts as closed"
           (window-closed-p window))
    (check "a released window is no longer among the windows"
           (not (member window (windows))))
    (check "a released window is refused instead of crashing the process"
           (every (lambda (f)
                    (handler-case (progn (funcall f window) nil)
                      (window-closed () t)))
                  (list #'window-title #'window-number #'window-frame
                        #'show-window #'window-scale-factor
                        (lambda (w) (setf (window-alpha w) 0.5))
                        (lambda (w) (setf (window-event-handler w) nil)))))))

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
    (let ((worker nil) (finished nil) (defaults *window-defaults*))
      ;; Test windows are invisible, so a test run does not flash on the
      ;; screen; CL_IRIS_TEST_VISIBLE=1 shows them. Set globally: the checks
      ;; run in another thread, which does not see this thread's bindings.
      (unless (sb-ext:posix-getenv "CL_IRIS_TEST_VISIBLE")
        (setf *window-defaults* (list* :alpha 0 defaults)))
      (unwind-protect
           (run-application
            ;; Tests run often and must not take focus or add a Dock icon.
            :activation-policy :accessory
            :on-launch (lambda ()
                         (setf worker
                               (sb-thread:make-thread
                                (lambda ()
                                  (unwind-protect (progn (mapc #'funcall checks)
                                                         (setf finished t))
                                    (stop-application)))
                                :name "cl-iris test worker"))))
        (setf *window-defaults* defaults))
      ;; The loop must not end under the checks: finish them before going on.
      (when worker
        (sb-thread:join-thread worker :default nil))
      (check "the application loop ran until the checks finished"
             finished))
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
           (= before (handle-count))))
  (application-delegate-checks))

(defun application-delegate-checks ()
  "Checks of quitting and reopening. Called on the main thread, outside any
application, since each runs an application of its own."
  (let ((requests 0) (reopened '()) (last-window nil) (worker nil))
    (run-application
     :activation-policy :accessory
     ;; Refuse the first request, accept the second.
     :on-quit-request (lambda () (>= (incf requests) 2))
     :on-reopen (lambda (visible) (push visible reopened))
     :quit-on-last-window-closed t
     :on-launch
     (lambda ()
       (setf worker
             (sb-thread:make-thread
              (lambda ()
                (let ((delegate (on-main (lambda () (send (cl-iris/window::app) "delegate")))))
                  (on-main (lambda ()
                             (send delegate "applicationShouldHandleReopen:hasVisibleWindows:"
                                   :pointer (cffi:null-pointer) :bool nil :bool)))
                  (setf last-window
                        (on-main (lambda ()
                                   (send delegate "applicationShouldTerminateAfterLastWindowClosed:"
                                         :pointer (cffi:null-pointer) :bool))))
                  (quit-application)
                  (check "a refused quit request keeps the loop running"
                         (and (= 1 requests) (application-running-p)))
                  (quit-application)
                  ;; Stop the loop ourselves only if the accepted request did not.
                  (unless (eventually (lambda () (not (application-running-p))) :timeout 2)
                    (stop-application))))))))
    (sb-thread:join-thread worker :default nil)
    (check "an accepted quit request stops the loop"
           (= 2 requests))
    (check "reopening calls the handler with whether a window is visible"
           (equal '(nil) reopened))
    (check "closing the last window can count as a request to quit"
           last-window)))

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
