;;;; Files dragged onto a webview (wry's drag and drop handler).
;;;;
;;;; :ON-DRAG-DROP is called with :ENTER, :OVER, :DROP or :LEAVE, the paths of
;;;; the files being dragged and the position, (x y) from the webview's
;;;; top-left corner. Returning true from :ENTER, :OVER or :DROP takes the
;;;; drag from WebKit; otherwise the page sees it as usual.

(in-package #:cl-iris/webview)

(defconstant +drag-operation-none+ 0)
(defconstant +drag-operation-copy+ 1)

(defun dragged-paths (info)
  "The paths of the files on the dragging pasteboard of INFO."
  (let* ((options (send (find-class* "NSDictionary") "dictionaryWithObject:forKey:"
                        :pointer (lisp->objc t)
                        :pointer (cffi:mem-ref (cffi:foreign-symbol-pointer
                                                "NSPasteboardURLReadingFileURLsOnlyKey")
                                               :pointer)))
         (urls (send (send info "draggingPasteboard") "readObjectsForClasses:options:"
                     :pointer (send (find-class* "NSArray") "arrayWithObject:"
                                    :pointer (find-class* "NSURL"))
                     :pointer options)))
    (unless (cffi:null-pointer-p urls)
      (url-paths urls))))

(defun dragging-location (info)
  "Where INFO's drag is, in its window's coordinates."
  (send info "draggingLocation" (:struct ns-point)))

(defun drag-position (webview info)
  "Where INFO's drag is, as (x y) from WEBVIEW's top-left corner."
  (let* ((point (send webview "convertPoint:fromView:"
                      (:struct ns-point) (dragging-location info)
                      :pointer (cffi:null-pointer)
                      (:struct ns-point)))
         (height (rect-height (send webview "bounds" (:struct ns-rect)))))
    ;; WKWebView is flipped: its y already counts from the top.
    (list (point-x point)
          (if (send webview "isFlipped" :bool)
              (point-y point)
              (- height (point-y point))))))

(defun drag-event (webview event info)
  "Tell :ON-DRAG-DROP about EVENT; true if the handler takes the drag."
  (when (and (route webview :on-drag-drop)
             (not (cffi:null-pointer-p info)))
    (let ((paths (dragged-paths info)))
      (when paths
        (multiple-value-bind (take handled)
            (call-handler webview :on-drag-drop "on-drag-drop"
                          event paths (drag-position webview info))
          (and handled take t))))))
