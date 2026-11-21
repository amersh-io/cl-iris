;;;; cl-iris/webview -- WKWebView with a two-way bridge to Lisp.
;;;;
;;;; JavaScript -> Lisp: window.webkit.messageHandlers.iris.postMessage(x)
;;;;   calls the webview's ON-MESSAGE function on the main thread.
;;;; Lisp -> JavaScript: EVAL-JS.
;;;; Pages from Lisp: a custom URL scheme whose requests ON-REQUEST answers.

(defpackage #:cl-iris/webview
  (:use #:cl #:cl-iris/objc #:cl-iris/window)
  (:export #:webview
           #:webview-pointer
           #:webview-window
           #:find-webview
           #:webviews
           #:make-webview
           #:destroy-webview
           #:load-url
           #:load-html
           #:add-init-script
           #:webview-user-agent
           #:webview-devtools-p
           #:webview-navigation-gestures-p
           #:webview-visible-p
           #:webview-transparent-p
           #:webview-autoplay-p
           #:webview-incognito-p
           #:webview-background-throttling
           #:webview-proxy-count
           #:webview-accepts-first-mouse-p
           #:webview-bounds
           #:webview-background-color
           #:webview-url
           #:reload
           #:can-go-back-p
           #:can-go-forward-p
           #:go-back
           #:go-forward
           #:focus-webview
           #:webview-focused-p
           #:focus-parent
           #:webview-zoom
           #:cookies
           #:set-cookie
           #:delete-cookie
           #:clear-browsing-data
           #:print-webview
           #:eval-js
           #:javascript-error
           #:request
           #:request-url
           #:request-method
           #:request-headers
           #:request-header
           #:request-body
           #:responder
           #:responder-request
           #:responder-open-p
           #:respond))
