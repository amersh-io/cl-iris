;;;; Loading AppKit.

(in-package #:cl-iris/window)

(cffi:define-foreign-library appkit
  (:darwin "/System/Library/Frameworks/AppKit.framework/AppKit"))

(cffi:use-foreign-library appkit)
