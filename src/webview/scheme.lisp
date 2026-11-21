;;;; Custom URL schemes: requests answered by Lisp (WKURLSchemeHandler).

(in-package #:cl-iris/webview)

(defstruct (request (:constructor %make-request (url method headers body)))
  "A request a page made for a custom scheme."
  (url "" :type string :read-only t)
  (method "GET" :type string :read-only t)
  (headers '() :type list :read-only t)
  (body nil :read-only t))

(setf (documentation 'request-url 'function) "The request's full URL."
      (documentation 'request-method 'function) "The HTTP method, e.g. \"GET\"."
      (documentation 'request-headers 'function)
      "The request's headers, an alist of (name . value) strings."
      (documentation 'request-body 'function)
      "The request's body as octets, or NIL when it has none.")

(defun request-header (request name)
  "The value of the header NAME in REQUEST, compared case-insensitively."
  (cdr (assoc name (request-headers request) :test #'string-equal)))

(defun octets-of (data)
  "The bytes of the NSData DATA as a Lisp vector, or NIL for nil."
  (unless (cffi:null-pointer-p data)
    (let* ((length (send data "length" :unsigned-long))
           (octets (make-array length :element-type '(unsigned-byte 8))))
      (when (plusp length)
        (cffi:with-pointer-to-vector-data (destination octets)
          (cffi:foreign-funcall "memcpy" :pointer destination
                                         :pointer (send data "bytes")
                                         :size length :pointer)))
      octets)))

(defun dictionary-alist (dictionary)
  "The NSDictionary of strings DICTIONARY as an alist, sorted by key."
  (unless (cffi:null-pointer-p dictionary)
    (let ((alist '()))
      (maphash (lambda (key value) (push (cons key value) alist))
               (objc->lisp dictionary))
      (sort alist #'string< :key #'car))))

(defun task-request (task)
  "The Lisp REQUEST for the WKURLSchemeTask TASK."
  (let ((request (send task "request")))
    (%make-request (lisp-string (send (send request "URL") "absoluteString"))
                   (lisp-string (send request "HTTPMethod"))
                   (dictionary-alist (send request "allHTTPHeaderFields"))
                   (octets-of (send request "HTTPBody")))))

;;; Answering a task

(defun ns-data (octets)
  (let ((octets (coerce octets '(simple-array (unsigned-byte 8) (*)))))
    (cffi:with-pointer-to-vector-data (bytes octets)
      (send (find-class* "NSData") "dataWithBytes:length:"
            :pointer bytes :unsigned-long (length octets)))))

(defun to-octets (body)
  (if (stringp body)
      (sb-ext:string-to-octets body :external-format :utf-8)
      body))

(defun header-dictionary (content-type headers)
  (let ((dictionary (send (find-class* "NSMutableDictionary") "dictionary")))
    (flet ((put (name value)
             (send dictionary "setObject:forKey:"
                   :pointer (ns-string (princ-to-string value))
                   :pointer (ns-string name)
                   :void)))
      (put "Content-Type" content-type)
      (loop for (name . value) in headers do (put name value)))
    dictionary))

(defun send-response (task status content-type headers octets)
  "Answer TASK with a complete response. Main thread only."
  (let ((response (send (send (find-class* "NSHTTPURLResponse") "alloc")
                        "initWithURL:statusCode:HTTPVersion:headerFields:"
                        :pointer (send (send task "request") "URL")
                        :long status
                        :pointer (ns-string "HTTP/1.1")
                        :pointer (header-dictionary content-type headers))))
    (send task "didReceiveResponse:" :pointer response :void)
    (release response)
    (send task "didReceiveData:" :pointer (ns-data octets) :void)
    (send task "didFinish" :void)))

(defun answer (task body &optional content-type status headers)
  "Answer TASK from the values a handler returned: BODY (a string, octets, or
NIL for 404), then optionally CONTENT-TYPE, STATUS and HEADERS (an alist)."
  (if (null body)
      (send-response task (or status 404) "text/plain; charset=utf-8" headers
                     (to-octets "Not found"))
      (send-response task (or status 200)
                     (or content-type "text/html; charset=utf-8")
                     headers (to-octets body))))

(defun protocol-handler (webview task)
  "The handler WEBVIEW has for the scheme of TASK's URL."
  (let ((scheme (string-downcase
                 (lisp-string (send (send (send task "request") "URL") "scheme")))))
    (second (assoc scheme (route webview :protocols) :test #'string=))))

(defun start-task (webview task)
  (let ((handler (protocol-handler webview task))
        (request (task-request task)))
    (multiple-value-bind (body content-type status headers)
        (handler-case (and handler (funcall handler request))
          (serious-condition (c)
            (report-error (format nil "on-request for ~A" (request-url request)) c)
            (values :error)))
      (if (eq body :error)
          (send-response task 500 "text/plain; charset=utf-8" '()
                         (to-octets "Internal error"))
          (answer task body content-type status headers)))))
