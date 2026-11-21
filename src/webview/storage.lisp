;;;; Cookies and stored website data.

(in-package #:cl-iris/webview)

(define-block-invoker array-received :void ((array :pointer)))
(define-block-invoker finished :void ())

(defun data-store (webview)
  (send (configuration webview) "websiteDataStore"))

(defun cookie-store (webview)
  (send (data-store webview) "httpCookieStore"))

(defun wait-on-main (description function)
  "Run FUNCTION on the main thread with a REPLY function, and wait until it
is called; DESCRIPTION names the operation if WebKit drops its handler."
  (on-main-deferred
   (lambda (reply fail)
     (funcall function reply
              (lambda () (funcall fail (make-condition
                                        'simple-error
                                        :format-control "WebKit dropped the handler for ~A."
                                        :format-arguments (list description))))))))

;;; Cookies, as plists:
;;;   (:name "a" :value "1" :domain "example.com" :path "/"
;;;    :expires <universal time or NIL for a session cookie> :secure NIL :http-only NIL)

(defun cookie-key (name)
  "The value of Foundation's NSHTTPCookie<NAME> property key."
  (cffi:mem-ref (cffi:foreign-symbol-pointer (format nil "NSHTTPCookie~A" name)) :pointer))

(defconstant +unix-epoch+ (encode-universal-time 0 0 0 1 1 1970 0))

(defun cookie-plist (cookie)
  (let ((expires (send cookie "expiresDate")))
    (list :name (lisp-string (send cookie "name"))
          :value (lisp-string (send cookie "value"))
          :domain (lisp-string (send cookie "domain"))
          :path (lisp-string (send cookie "path"))
          :expires (unless (cffi:null-pointer-p expires)
                     (+ +unix-epoch+ (round (send expires "timeIntervalSince1970" :double))))
          :secure (send cookie "isSecure" :bool)
          :http-only (send cookie "isHTTPOnly" :bool))))

(defun ns-cookie (&key name value domain (path "/") expires secure http-only)
  "An NSHTTPCookie from the parts of a cookie plist."
  (let ((properties (send (find-class* "NSMutableDictionary") "dictionary")))
    (flet ((put (key object)
             (send properties "setObject:forKey:" :pointer object :pointer (cookie-key key) :void)))
      (put "Name" (ns-string name))
      (put "Value" (ns-string value))
      (put "Domain" (ns-string domain))
      (put "Path" (ns-string path))
      (when expires
        (put "Expires" (send (find-class* "NSDate") "dateWithTimeIntervalSince1970:"
                             :double (float (- expires +unix-epoch+) 1d0))))
      (when secure (put "Secure" (ns-string "TRUE")))
      (when http-only
        (send properties "setObject:forKey:" :pointer (ns-string "TRUE")
                                             :pointer (ns-string "HttpOnly") :void)))
    (let ((cookie (send (find-class* "NSHTTPCookie") "cookieWithProperties:" :pointer properties)))
      (when (cffi:null-pointer-p cookie)
        (error "Not a valid cookie: ~S" (list :name name :domain domain :path path)))
      cookie)))

(defun cookie-matches-url-p (cookie url)
  "True if COOKIE would be sent with a request for URL."
  (let* ((object (ns-url url))
         (host (lisp-string (send object "host")))
         (path (let ((p (send object "path"))) (if (cffi:null-pointer-p p) "/" (lisp-string p))))
         (domain (string-left-trim "." (getf cookie :domain))))
    (and (or (string-equal host domain)
             (let ((suffix (concatenate 'string "." domain)))
               (and (> (length host) (length suffix))
                    (string-equal suffix host :start2 (- (length host) (length suffix))))))
         (eql 0 (search (getf cookie :path) (if (string= path "") "/" path)))
         (or (not (getf cookie :secure))
             (string-equal "https" (lisp-string (send object "scheme")))))))

(defun cookies (webview &key url)
  "The cookies WEBVIEW's data store holds, as plists; with URL, only those it
would send to URL."
  (let ((all (wait-on-main
              "getAllCookies:"
              (lambda (reply dropped)
                (let ((block (make-block (cffi:callback array-received)
                                         (lambda (array)
                                           (funcall reply
                                                    (loop for i below (send array "count" :unsigned-long)
                                                          collect (cookie-plist
                                                                   (send array "objectAtIndex:"
                                                                         :unsigned-long i)))))
                                         :on-drop dropped)))
                  (send (cookie-store webview) "getAllCookies:" :pointer block :void)
                  (release-block block))))))
    (if url
        (remove-if-not (lambda (cookie) (cookie-matches-url-p cookie url)) all)
        all)))

(defun call-cookie-store (webview selector cookie)
  (wait-on-main
   selector
   (lambda (reply dropped)
     (let ((block (make-block (cffi:callback finished) (lambda () (funcall reply t))
                              :on-drop dropped)))
       (send (cookie-store webview) selector
             :pointer (apply #'ns-cookie cookie) :pointer block :void)
       (release-block block)))))

(defun set-cookie (webview &rest cookie &key name value domain path expires secure http-only)
  "Store a cookie in WEBVIEW's data store and wait until it is there. DOMAIN
and NAME are required; PATH defaults to \"/\"; EXPIRES is a universal time,
or NIL for a session cookie."
  (declare (ignore path expires secure http-only))
  (unless (and name value domain)
    (error "A cookie needs a :NAME, a :VALUE and a :DOMAIN."))
  (call-cookie-store webview "setCookie:completionHandler:" cookie)
  nil)

(defun delete-cookie (webview cookie)
  "Remove COOKIE, a plist as COOKIES returns, from WEBVIEW's data store."
  (call-cookie-store webview "deleteCookie:completionHandler:"
                     (list :name (getf cookie :name) :value (getf cookie :value)
                           :domain (getf cookie :domain) :path (or (getf cookie :path) "/")))
  nil)

;;; All website data

(defun clear-browsing-data (webview)
  "Remove everything WEBVIEW's data store holds -- cookies, local storage,
caches, databases -- and wait until it is gone. Every webview sharing the
store (all but incognito ones, by default) loses it too."
  (wait-on-main
   "removeDataOfTypes:modifiedSince:completionHandler:"
   (lambda (reply dropped)
     (let ((block (make-block (cffi:callback finished) (lambda () (funcall reply t))
                              :on-drop dropped)))
       (send (data-store webview) "removeDataOfTypes:modifiedSince:completionHandler:"
             :pointer (send (find-class* "WKWebsiteDataStore") "allWebsiteDataTypes")
             :pointer (send (find-class* "NSDate") "distantPast")
             :pointer block
             :void)
       (release-block block))))
  nil)
