;;;; The menu bar.
;;;;
;;;; A menu bar is described as a list of menus:
;;;;
;;;;   (:menu TITLE ITEM*)
;;;;
;;;; and each ITEM is :SEPARATOR, a submenu (:MENU ...), or
;;;;
;;;;   (:item TITLE &key key modifiers action selector (enabled t) checked)
;;;;
;;;; KEY is the key equivalent, a one-character string; MODIFIERS a list of
;;;; :COMMAND, :SHIFT, :OPTION and :CONTROL (default (:COMMAND) when there is
;;;; a KEY). ACTION is a Lisp function of no arguments, called on the main
;;;; thread; SELECTOR instead names an Objective-C action sent along the
;;;; responder chain, such as "copy:" — which is how the Edit menu reaches a
;;;; webview. The first menu is the application menu; macOS shows the
;;;; application's name as its title.

(in-package #:cl-iris/window)

(defvar *menu-actions* (make-hash-table)
  "Lisp menu items of the current menu bar: tag -> (function . enabled).
Main thread only.")

(defvar *menu-target* nil
  "The object Lisp menu items send their action to. Menu items do not retain
their target, so the menu bar's own target is kept here.")

(define-objc-class "CLIrisMenuTarget" ()
  (:method "performLispAction:" :void (self (item :pointer))
    (let ((entry (gethash (send item "tag" :long) *menu-actions*)))
      (when entry
        (funcall (car entry)))))
  (:method "validateMenuItem:" :bool (self (item :pointer))
    (let ((entry (gethash (send item "tag" :long) *menu-actions*)))
      (and entry (cdr entry) t))))

(defparameter *modifier-bits*
  '((:shift . #.(ash 1 17))
    (:control . #.(ash 1 18))
    (:option . #.(ash 1 19))
    (:command . #.(ash 1 20))))

(defun modifier-mask (modifiers)
  (reduce #'logior modifiers
          :key (lambda (m)
                 (or (cdr (assoc m *modifier-bits*))
                     (error "Unknown modifier ~S; expected one of ~S."
                            m (mapcar #'car *modifier-bits*))))
          :initial-value 0))

(defvar *next-menu-tag* 0)

(defun build-item (spec target)
  (destructuring-bind (title &key key (modifiers (and key '(:command)))
                               action selector (enabled t) checked)
      (rest spec)
    (when (and action selector)
      (error "Menu item ~S has both an :ACTION and a :SELECTOR." title))
    (let ((item (autorelease
                 (send (send (find-class* "NSMenuItem") "alloc")
                       "initWithTitle:action:keyEquivalent:"
                       :pointer (ns-string title)
                       :pointer (cond (action (selector "performLispAction:"))
                                      (selector (selector selector))
                                      (t (cffi:null-pointer)))
                       :pointer (ns-string (or key ""))))))
      (when key
        (send item "setKeyEquivalentModifierMask:" :unsigned-long (modifier-mask modifiers) :void))
      (when action
        (let ((tag (incf *next-menu-tag*)))
          (setf (gethash tag *menu-actions*) (cons action enabled))
          (send item "setTag:" :long tag :void)
          (send item "setTarget:" :pointer target :void)))
      (when checked
        (send item "setState:" :long 1 :void))
      item)))

(defun build-menu (spec target)
  (destructuring-bind (keyword title &rest items) spec
    (unless (eq keyword :menu)
      (error "Expected (:menu TITLE ITEM*), got ~S." spec))
    (let ((menu (autorelease (send (send (find-class* "NSMenu") "alloc") "initWithTitle:"
                                   :pointer (ns-string title)))))
      (dolist (item items menu)
        (send menu "addItem:"
              :pointer (cond ((eq item :separator)
                              (send (find-class* "NSMenuItem") "separatorItem"))
                             ((and (consp item) (eq (first item) :menu))
                              (submenu-item (build-menu item target)))
                             ((and (consp item) (eq (first item) :item))
                              (build-item item target))
                             (t (error "Not a menu item: ~S" item)))
              :void)))))

(defun submenu-item (menu)
  (let ((item (autorelease (send (send (find-class* "NSMenuItem") "alloc") "init"))))
    (send item "setTitle:" :pointer (send menu "title") :void)
    (send item "setSubmenu:" :pointer menu :void)
    item))

(defun install-menu-bar (spec)
  "Build SPEC and make it the menu bar, replacing the Lisp actions of the
previous one; a malformed SPEC leaves the current menu bar as it is. Main
thread."
  (let ((target (send (send (find-class* "CLIrisMenuTarget") "alloc") "init"))
        (actions (make-hash-table))
        (bar nil))
    (handler-bind ((serious-condition (lambda (c) (declare (ignore c)) (release target))))
      (let ((*menu-actions* actions))
        (setf bar (autorelease (send (send (find-class* "NSMenu") "alloc") "init")))
        (dolist (menu spec)
          (send bar "addItem:" :pointer (submenu-item (build-menu menu target)) :void))))
    (send (app) "setMainMenu:" :pointer bar :void)
    (let ((window-menu (find-submenu bar "Window")))
      (when window-menu
        (send (app) "setWindowsMenu:" :pointer window-menu :void)))
    (let ((old-target *menu-target*))
      (setf *menu-actions* actions
            *menu-target* target)
      (when old-target (release old-target)))))

(defun set-menu-bar (spec)
  "Replace the menu bar with SPEC (see the top of this file); NIL removes it."
  (on-main (lambda () (install-menu-bar spec)))
  nil)

;;; Finding items

(defun find-submenu (menu title)
  (let ((item (send menu "itemWithTitle:" :pointer (ns-string title))))
    (unless (cffi:null-pointer-p item)
      (let ((submenu (send item "submenu")))
        (unless (cffi:null-pointer-p submenu) submenu)))))

(defun find-menu-item (&rest path)
  "Return the menu item at PATH, a list of titles from the menu bar down
(\"Edit\" \"Copy\"), or NIL."
  (on-main
   (lambda ()
     (let ((menu (send (app) "mainMenu")))
       (unless (cffi:null-pointer-p menu)
         (loop for (title . more) on path
               for item = (send menu "itemWithTitle:" :pointer (ns-string title))
               do (when (cffi:null-pointer-p item) (return nil))
                  (if more
                      (progn (setf menu (send item "submenu"))
                             (when (cffi:null-pointer-p menu) (return nil)))
                      (return item))))))))

(defun menu-item-enabled-p (item)
  (on-main (lambda ()
             (send (send item "menu") "update" :void)
             (send item "isEnabled" :bool))))

(defun (setf menu-item-enabled-p) (enabled item)
  "Enable or disable a menu item that has a Lisp action."
  (on-main (lambda ()
             (let ((entry (gethash (send item "tag" :long) *menu-actions*)))
               (unless entry
                 (error "Only menu items with a Lisp :ACTION can be enabled from Lisp."))
               (setf (cdr entry) enabled))))
  enabled)

(defun menu-item-checked-p (item)
  (on-main (lambda () (= 1 (send item "state" :long)))))

(defun (setf menu-item-checked-p) (checked item)
  (on-main (lambda () (send item "setState:" :long (if checked 1 0) :void)))
  checked)

(defun perform-menu-item (item)
  "Do what choosing ITEM does, as if the user had chosen it."
  (on-main (lambda ()
             (let ((menu (send item "menu")))
               (send menu "performActionForItemAtIndex:"
                     :long (send menu "indexOfItem:" :pointer item :long) :void))))
  nil)

;;; The standard menu bar

(defun application-name ()
  "The application's name: the bundle's name when running from a .app,
otherwise the process name."
  (on-main
   (lambda ()
     (let* ((bundle (send (find-class* "NSBundle") "mainBundle"))
            (name (send bundle "objectForInfoDictionaryKey:" :pointer (ns-string "CFBundleName"))))
       (lisp-string (if (cffi:null-pointer-p name)
                        (send (send (find-class* "NSProcessInfo") "processInfo") "processName")
                        name))))))

(defun default-menu-bar (&key (name (application-name)))
  "The menu bar every Mac application has: the application menu (About,
Hide, Quit), Edit, View and Window. The Edit menu is what makes Cmd+C,
Cmd+V, Cmd+A and undo work in a webview. Extend or replace parts of it
before giving it to SET-MENU-BAR."
  `((:menu ,name
     (:item ,(format nil "About ~A" name) :selector "orderFrontStandardAboutPanel:")
     :separator
     (:item ,(format nil "Hide ~A" name) :key "h" :selector "hide:")
     (:item "Hide Others" :key "h" :modifiers (:command :option)
            :selector "hideOtherApplications:")
     (:item "Show All" :selector "unhideAllApplications:")
     :separator
     (:item ,(format nil "Quit ~A" name) :key "q" :selector "terminate:"))
    (:menu "Edit"
     (:item "Undo" :key "z" :selector "undo:")
     (:item "Redo" :key "z" :modifiers (:command :shift) :selector "redo:")
     :separator
     (:item "Cut" :key "x" :selector "cut:")
     (:item "Copy" :key "c" :selector "copy:")
     (:item "Paste" :key "v" :selector "paste:")
     (:item "Paste and Match Style" :key "v" :modifiers (:command :option :shift)
            :selector "pasteAsPlainText:")
     (:item "Delete" :selector "delete:")
     (:item "Select All" :key "a" :selector "selectAll:"))
    (:menu "View"
     (:item "Enter Full Screen" :key "f" :modifiers (:command :control)
            :selector "toggleFullScreen:"))
    (:menu "Window"
     (:item "Minimize" :key "m" :selector "performMiniaturize:")
     (:item "Zoom" :selector "performZoom:")
     (:item "Close" :key "w" :selector "performClose:")
     :separator
     (:item "Bring All to Front" :selector "arrangeInFront:"))))
