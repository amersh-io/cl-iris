;;;; Printing a webview's page, to a printer through the print panel or
;;;; straight to a PDF file.

(in-package #:cl-iris/webview)

(defun print-info (pdf)
  "A print info for an operation: a copy of the shared one, saving to the
file PDF instead of printing when PDF is given."
  (let ((info (send (send (find-class* "NSPrintInfo") "sharedPrintInfo") "copy")))
    (when pdf
      (send info "setJobDisposition:"
            :pointer (cffi:mem-ref (cffi:foreign-symbol-pointer "NSPrintSaveJob") :pointer)
            :void)
      (send (send info "dictionary") "setObject:forKey:"
            :pointer (send (find-class* "NSURL") "fileURLWithPath:"
                           :pointer (ns-string (namestring pdf)))
            :pointer (cffi:mem-ref (cffi:foreign-symbol-pointer "NSPrintJobSavingURL") :pointer)
            :void))
    (autorelease info)))

(defun print-webview (webview &key pdf)
  "Print WEBVIEW's page: show the print panel as a sheet on its window, or,
with PDF, a pathname, write the page to that file without asking. Returns at
once; the operation runs on the main thread."
  (on-main
   (lambda ()
     (let ((window (send webview "window")))
       (when (cffi:null-pointer-p window)
         (error "This webview is not in a window."))
       (let ((operation (send webview "printOperationWithPrintInfo:"
                              :pointer (print-info pdf))))
         (send operation "setShowsPrintPanel:" :bool (not pdf) :void)
         (send operation "setShowsProgressPanel:" :bool nil :void)
         ;; WebKit lays the page out for printing from the view's frame.
         (send (send operation "view") "setFrame:" (:struct ns-rect)
               (send webview "bounds" (:struct ns-rect)) :void)
         (send operation "runOperationModalForWindow:delegate:didRunSelector:contextInfo:"
               :pointer window :pointer (cffi:null-pointer)
               :pointer (cffi:null-pointer) :pointer (cffi:null-pointer)
               :void)))))
  nil)
