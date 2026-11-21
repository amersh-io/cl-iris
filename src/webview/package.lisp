;;;; cl-iris/webview -- WKWebView with a two-way bridge to Lisp.
;;;;
;;;; JavaScript -> Lisp: window.webkit.messageHandlers.iris.postMessage(x)
;;;;   calls the webview's ON-MESSAGE function on the main thread.
;;;; Lisp -> JavaScript: EVAL-JS.
;;;; Pages from Lisp: a custom URL scheme whose requests ON-REQUEST answers.

(defpackage #:cl-iris/webview
  (:use #:cl #:cl-iris/objc #:cl-iris/window)
  (:import-from #:cl-iris/window #:register-task #:take-task)
  (:export #:make-webview
           #:destroy-webview
           #:load-url
           #:load-html
           #:eval-js
           #:javascript-error))
