;;;; The CL-IRIS package: windows and webviews in one place.
;;;;
;;;; It re-exports every external symbol of CL-IRIS/WINDOW and CL-IRIS/WEBVIEW,
;;;; which is what an application uses. The Objective-C layer, CL-IRIS/OBJC,
;;;; stays a package of its own, for code that goes below them.

(uiop:define-package #:cl-iris
  (:use-reexport #:cl-iris/window #:cl-iris/webview)
  (:documentation "Native windows and webviews: the external symbols of
CL-IRIS/WINDOW and CL-IRIS/WEBVIEW. CL-IRIS/OBJC is the layer below."))
