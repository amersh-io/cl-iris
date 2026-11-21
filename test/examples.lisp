;;;; Every example in examples/ is run in a child Lisp: it must open its
;;;; windows, load its pages without an error, and answer a probe.

(in-package #:cl-iris/test)

(defparameter *examples*
  ;; file, a script run in its first webview, and what its title becomes.
  '(("hello" nil "Hello from cl-iris")
    ("ipc" "iris.invoke({op: 'add', args: [2, 40]}).then(v => document.title = 'sum ' + v); 0"
     "sum 42")
    ("custom-protocol" "fetch('/api/echo', {method: 'POST', body: 'hi'}).then(r => r.text()).then(t => document.title = t); 0"
     "POST hi")
    ("menu" nil "Menu")
    ("multi-window" nil "Left")))

(defparameter *example-driver* "
(sb-thread:make-thread
 (lambda ()
   (loop until (cl-iris:application-running-p) do (sleep 0.05))
   (unwind-protect
        (handler-case
            (flet ((titles ()
                     (mapcar (lambda (w) (cl-iris:eval-js w \"document.title\" :timeout 5))
                             (cl-iris:webviews))))
              (loop repeat 100
                    until (let ((titles (titles)))
                            (and titles (every (lambda (title) (plusp (length title))) titles)))
                    do (sleep 0.1))
              (format t \"~&EXAMPLE-WINDOWS ~D~%\" (length (cl-iris:windows)))
              (format t \"~&EXAMPLE-TITLES ~{~A~^|~}~%\" (titles))
              (when cl-user::*probe*
                (let ((webview (first (last (cl-iris:webviews)))))
                  (cl-iris:eval-js webview cl-user::*probe*)
                  (loop repeat 100
                        until (member cl-user::*expected* (titles) :test #'string=)
                        do (sleep 0.1))
                  (format t \"~&EXAMPLE-PROBED ~{~A~^|~}~%\" (titles)))))
          (error (e) (format t \"~&EXAMPLE-ERROR ~A~%\" e)))
     (cl-iris:stop-application))))")

(defun last-lines (text count)
  "The last COUNT lines of TEXT."
  (let ((lines (uiop:split-string (string-right-trim '(#\Newline) text) :separator '(#\Newline))))
    (format nil "~{~A~^~%~}" (last lines count))))

(defun run-example (name probe)
  (let ((file (namestring (merge-pathnames (format nil "examples/~A.lisp" name)
                                           (asdf:system-source-directory "cl-iris")))))
    (run-child-lisp "(pushnew :cl-iris-example-test *features*)"
                    "(asdf:load-system \"cl-iris\")"
                    ;; Out of sight, like every test window.
                    "(setf cl-iris:*window-defaults* '(:alpha 0 :activate nil))"
                    (format nil "(defparameter cl-user::*probe* ~S)" (first probe))
                    (format nil "(defparameter cl-user::*expected* ~S)" (second probe))
                    (format nil "(load ~S)" file)
                    *example-driver*
                    (format nil "(~A::main :activation-policy :accessory)"
                            (format nil "cl-iris.examples.~A" name))
                    "(format t \"~&EXAMPLE-DONE~%\")")))

(defun example-checks ()
  (loop for (name script expected) in *examples*
        do (when (selected-p (format nil "the ~A example" name))
             (multiple-value-bind (output code)
                 (run-example name (list script expected))
               (check (format nil "the ~A example opens its windows and pages" name)
                      (or (and (eql 0 code)
                               (search "EXAMPLE-DONE" output)
                               (not (search "EXAMPLE-ERROR" output))
                               (not (search ";; cl-iris: error" output))
                               (search (if script "EXAMPLE-TITLES" (format nil "EXAMPLE-TITLES ~A" expected))
                                       output))
                          ;; Show what the child said, so a failure elsewhere
                          ;; (CI) can be read from the log.
                          (progn (format t "~&;; ~A example, exit code ~A, output:~%~A~%"
                                         name code (last-lines output 40))
                                 nil)))
               (when script
                 (check (format nil "the ~A example answers its probe" name)
                        (search expected (or (subseq output (or (search "EXAMPLE-PROBED" output) 0))
                                             ""))))))))
