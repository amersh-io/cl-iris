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

;;; Answering
;;;
;;; WebKit may stop a task at any time before it ends (the page navigated
;;; away, a fetch was aborted), and sending anything to a stopped or ended
;;; task raises an Objective-C exception, which aborts the process. So every
;;; task gets a fresh integer id when it starts, and a main-thread table holds
;;; the task (retained) under that id while it is open. Stopping closes the
;;; entry; all sending goes through ANSWER-TASK, on the main thread, which
;;; sends only while the entry is open and closes it. A responder holds only
;;; the id, never the task: ids are not reused, while task addresses are.
;;; The spec/ directory models this protocol (url-scheme-task.qnt).

(defvar *open-tasks* (make-hash-table)
  "Open tasks: id -> task, retained. Main thread only.")

(defvar *task-ids* (make-hash-table)
  "Open tasks: task address -> id, to find the entry WebKit stops. While a task
is open we hold a reference to it, so its address cannot be reused. Main
thread only.")

(defvar *next-task-id* 0)

(defun open-task (task)
  "Record TASK as open and return its new id."
  (let ((id (incf *next-task-id*)))
    (setf (gethash id *open-tasks*) (retain task)
          (gethash (cffi:pointer-address task) *task-ids*) id)
    id))

(defun close-task (id)
  (let ((task (gethash id *open-tasks*)))
    (when task
      (remhash id *open-tasks*)
      (remhash (cffi:pointer-address task) *task-ids*)
      (release task))))

(defun answer-task (id body &optional content-type status headers)
  "On the main thread: if task ID is still open, answer it from the values a
handler returned -- BODY (a string, octets, NIL for 404, or :ERROR for 500),
then optionally CONTENT-TYPE, STATUS and HEADERS (an alist) -- and close it.
Returns true if the answer was sent."
  (let ((task (gethash id *open-tasks*)))
    (when task
      (unwind-protect
           (cond ((eq body :error)
                  (send-response task 500 "text/plain; charset=utf-8" '()
                                 (to-octets "Internal error")))
                 ((null body)
                  (send-response task (or status 404) "text/plain; charset=utf-8" headers
                                 (to-octets "Not found")))
                 (t
                  (send-response task (or status 200)
                                 (or content-type "text/html; charset=utf-8")
                                 headers (to-octets body))))
        (close-task id))
      t)))

(defstruct (responder (:constructor %make-responder (id request)))
  "The way an asynchronous protocol handler answers its request, once."
  (id 0 :read-only t)
  (request nil :read-only t)
  (answered nil))

(setf (documentation 'responder-request 'function) "The REQUEST being answered.")

(defun respond (responder body &key content-type status headers)
  "Answer the request of RESPONDER, from any thread, with BODY (a string,
octets, or NIL for 404) and optionally CONTENT-TYPE, STATUS and HEADERS (an
alist). Returns at once. If WebKit has stopped the request meanwhile, the
answer is dropped; answering twice is an error, reported on the main thread."
  (on-main
   (lambda ()
     (when (responder-answered responder)
       (error "The request for ~A was already answered."
              (request-url (responder-request responder))))
     (setf (responder-answered responder) t)
     (answer-task (responder-id responder) body content-type status headers))
   :wait nil)
  nil)

(defun responder-open-p (responder)
  "True until RESPONDER has answered or WebKit has stopped its request."
  (on-main (lambda () (and (gethash (responder-id responder) *open-tasks*) t))))

(defun protocol (webview task)
  "The (SCHEME HANDLER . OPTIONS) entry WEBVIEW has for TASK's URL."
  (let ((scheme (string-downcase
                 (lisp-string (send (send (send task "request") "URL") "scheme")))))
    (assoc scheme (route webview :protocols) :test #'string=)))

(defun start-task (webview task)
  (let* ((entry (protocol webview task))
         (handler (second entry))
         (async (getf (cddr entry) :async)))
    (let ((request (task-request task))
          (id (open-task task)))
      (flet ((failed (c)
               (report-error (format nil "the protocol handler for ~A" (request-url request)) c)
               (answer-task id :error)))
        (cond ((null handler) (answer-task id nil))
              (async
               (handler-case (funcall handler request (%make-responder id request))
                 (serious-condition (c) (failed c))))
              (t
               ;; Through ANSWER-TASK too: a handler that runs a nested event
               ;; loop (a modal panel, say) may see the task stopped meanwhile.
               (multiple-value-bind (body content-type status headers)
                   (handler-case (funcall handler request)
                     (serious-condition (c) (failed c) (values nil)))
                 (answer-task id body content-type status headers))))))))

(defun stop-task (task)
  (let ((id (gethash (cffi:pointer-address task) *task-ids*)))
    (when id
      (close-task id))))
