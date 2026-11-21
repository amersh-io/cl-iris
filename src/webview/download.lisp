;;;; Downloads (WKDownload, macOS 11.3 and later).
;;;;
;;;; A navigation WebKit cannot show, or a link with the download attribute,
;;;; becomes a download. :ON-DOWNLOAD hears it start and chooses where it goes,
;;;; then hears it finish or fail.

(in-package #:cl-iris/webview)

(defvar *downloads* (make-hash-table)
  "Download address -> (webview . url), while it runs. Main thread only.")

(defun start-download (download)
  "A navigation became DOWNLOAD: take it over as its delegate."
  (let ((webview (send download "webView")))
    (send download "setDelegate:" :pointer (route webview :delegate) :void)
    (setf (gethash (cffi:pointer-address download) *downloads*)
          (cons webview (url-string (send (send download "originalRequest") "URL"))))))

(defun default-download-path (filename)
  "FILENAME in the user's Downloads folder."
  (let ((folders (send (send (find-class* "NSFileManager") "defaultManager")
                       "URLsForDirectory:inDomains:"
                       :unsigned-long 15        ; NSDownloadsDirectory
                       :unsigned-long 1)))      ; NSUserDomainMask
    (merge-pathnames filename
                     (uiop:ensure-directory-pathname
                      (lisp-string (send (send folders "firstObject") "path"))))))

(defun download-destination (download suggested completion)
  "Answer WebKit's COMPLETION block with the file DOWNLOAD should go to: what
:ON-DOWNLOAD returns for :STARTED, or the Downloads folder without one; NIL
cancels the download."
  (destructuring-bind (webview . url) (gethash (cffi:pointer-address download) *downloads*
                                               (list (cffi:null-pointer)))
    (let ((filename (lisp-string suggested)))
      (multiple-value-bind (path handled)
          (if (and webview (route webview :on-download))
              (call-handler webview :on-download "on-download" :started url filename)
              (values (default-download-path filename) t))
        (call-block completion
                    :pointer (if (and handled path)
                                 (send (find-class* "NSURL") "fileURLWithPath:"
                                       :pointer (ns-string (namestring path)))
                                 (cffi:null-pointer)))))))

(defun end-download (download event &optional detail)
  (let ((entry (gethash (cffi:pointer-address download) *downloads*)))
    (remhash (cffi:pointer-address download) *downloads*)
    (when entry
      (destructuring-bind (webview . url) entry
        (when (gethash (cffi:pointer-address webview) *routes*)
          (call-handler webview :on-download "on-download" event url detail))))))

(defun download-finished (download)
  (end-download download :finished))

(defun download-failed (download error)
  (end-download download :failed (lisp-string (send error "localizedDescription"))))
