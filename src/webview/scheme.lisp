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

(defun protocol (webview task)
  "The (SCHEME HANDLER . OPTIONS) entry WEBVIEW has for TASK's URL."
  (let ((scheme (string-downcase
                 (lisp-string (send (send (send task "request") "URL") "scheme")))))
    (assoc scheme (route webview :protocols) :test #'string=)))

(defun internal-error (task)
  (send-response task 500 "text/plain; charset=utf-8" '() (to-octets "Internal error")))

;;; Asynchronous answers
;;;
;;; An asynchronous handler gets a RESPONDER and may answer later, from any
;;; thread. WebKit may stop the task first (the page navigated away, a fetch
;;; was aborted), and touching a stopped task raises an Objective-C exception,
;;; which aborts the process. So the task is only ever touched on the main
;;; thread, where WebKit also stops it, and only while it is still open.

(defstruct (responder (:constructor %make-responder (task request)))
  "The way an asynchronous protocol handler answers its request, once."
  task
  (request nil :read-only t)
  (state :open))

(setf (documentation 'responder-request 'function) "The REQUEST being answered.")

(defvar *open-tasks* (make-hash-table)
  "Responders still waiting to answer, by task address. Main thread only.")

(defun close-responder (responder state)
  (let ((task (responder-task responder)))
    (remhash (cffi:pointer-address task) *open-tasks*)
    (setf (responder-state responder) state
          (responder-task responder) nil)
    (release task)))

(defun respond (responder body &key content-type status headers)
  "Answer the request of RESPONDER, from any thread, with BODY (a string,
octets, or NIL for 404) and optionally CONTENT-TYPE, STATUS and HEADERS (an
alist). Returns at once. If WebKit has stopped the request meanwhile, the
answer is dropped; answering twice is an error, reported on the main thread."
  (on-main
   (lambda ()
     (ecase (responder-state responder)
       (:open
        (unwind-protect
             (answer (responder-task responder) body content-type status headers)
          (close-responder responder :answered)))
       (:stopped nil)
       (:answered
        (error "The request for ~A was already answered."
               (request-url (responder-request responder))))))
   :wait nil)
  nil)

(defun responder-open-p (responder)
  "True until RESPONDER has answered or WebKit has stopped its request."
  (on-main (lambda () (eq :open (responder-state responder)))))

(defun start-task (webview task)
  (destructuring-bind (&optional scheme handler &key async) (protocol webview task)
    (declare (ignore scheme))
    (let ((request (task-request task)))
      (flet ((failed (c)
               (report-error (format nil "the protocol handler for ~A" (request-url request)) c)
               (internal-error task)))
        (cond ((null handler) (answer task nil))
              (async
               (let ((responder (%make-responder (retain task) request)))
                 (setf (gethash (cffi:pointer-address task) *open-tasks*) responder)
                 (handler-case (funcall handler request responder)
                   (serious-condition (c)
                     (close-responder responder :answered)
                     (failed c)))))
              (t
               (multiple-value-bind (body content-type status headers)
                   (handler-case (funcall handler request)
                     (serious-condition (c) (failed c) (values :error)))
                 (unless (eq body :error)
                   (answer task body content-type status headers)))))))))

(defun stop-task (task)
  (let ((responder (gethash (cffi:pointer-address task) *open-tasks*)))
    (when responder
      (close-responder responder :stopped))))
