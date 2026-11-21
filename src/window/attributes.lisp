;;;; Reading and changing a window's attributes.
;;;;
;;;; Positions and sizes are in points, in the screen's coordinates: the
;;;; origin is the bottom-left corner of the main screen and Y grows upwards,
;;;; as everywhere in AppKit.

(in-package #:cl-iris/window)

(defun (setf window-title) (title window)
  (on-window window (lambda () (send window "setTitle:" :pointer (ns-string title) :void)))
  title)

(defun resize-window (window width height)
  "Make WINDOW's content area WIDTH by HEIGHT points, keeping its bottom-left
corner in place."
  (on-window window
   (lambda ()
     (send window "setContentSize:" (:struct ns-size) (make-size width height) :void)))
  nil)

(defun window-frame (window)
  "Return the X, Y, width and height of WINDOW's whole frame, title bar
included."
  (on-window window
   (lambda ()
     (let ((frame (send window "frame" (:struct ns-rect))))
       (values (rect-x frame) (rect-y frame) (rect-width frame) (rect-height frame))))))

(defun window-position (window)
  "Return the X and Y of WINDOW's bottom-left corner."
  (multiple-value-bind (x y) (window-frame window)
    (values x y)))

(defun move-window (window x y)
  "Put WINDOW's bottom-left corner at X, Y."
  (on-window window
   (lambda ()
     (send window "setFrameOrigin:" (:struct ns-point) (make-point x y) :void)))
  nil)

(defun center-window (window)
  "Put WINDOW in the middle of its screen, a little above center as macOS
places new windows."
  (on-window window (lambda () (send window "center" :void)))
  nil)

(defun size-values (size)
  (values (size-width size) (size-height size)))

(defun window-min-size (window)
  "Return the smallest width and height the user can resize WINDOW's content
area to."
  (on-window window (lambda () (size-values (send window "contentMinSize" (:struct ns-size))))))

(defun set-window-min-size (window width height)
  "Keep the user from resizing WINDOW's content area below WIDTH by HEIGHT."
  (on-window window
   (lambda ()
     (send window "setContentMinSize:" (:struct ns-size) (make-size width height) :void)))
  nil)

(defun window-max-size (window)
  "Return the largest width and height the user can resize WINDOW's content
area to."
  (on-window window (lambda () (size-values (send window "contentMaxSize" (:struct ns-size))))))

(defun set-window-max-size (window width height)
  "Keep the user from resizing WINDOW's content area beyond WIDTH by HEIGHT."
  (on-window window
   (lambda ()
     (send window "setContentMaxSize:" (:struct ns-size) (make-size width height) :void)))
  nil)

;;; Style: the title bar, its buttons, and whether the user can resize.

(defparameter *style-bits*
  '((:titled . 1)
    (:closable . 2)
    (:miniaturizable . 4)
    (:resizable . 8)
    (:full-size-content-view . 32768))
  "NSWindowStyleMask bits by keyword. A window with none of them is borderless.")

(defparameter *default-style* '(:titled :closable :miniaturizable :resizable))

(defun style-mask (style)
  (reduce #'logior style
          :key (lambda (keyword)
                 (or (cdr (assoc keyword *style-bits*))
                     (error "Unknown window style ~S; expected one of ~S."
                            keyword (mapcar #'car *style-bits*))))
          :initial-value 0))

(defun style-keywords (mask)
  (loop for (keyword . bit) in *style-bits*
        when (logtest bit mask) collect keyword))

(defun window-style (window)
  "Return WINDOW's style as a list of keywords from :TITLED, :CLOSABLE,
:MINIATURIZABLE, :RESIZABLE and :FULL-SIZE-CONTENT-VIEW."
  (on-window window (lambda () (style-keywords (send window "styleMask" :unsigned-long)))))

(defun (setf window-style) (style window)
  (let ((mask (style-mask style)))
    (on-window window (lambda () (send window "setStyleMask:" :unsigned-long mask :void))))
  style)

(defun update-style (window keyword on)
  (let ((style (window-style window)))
    (setf (window-style window)
          (if on (adjoin keyword style) (remove keyword style)))))

(defun window-resizable-p (window)
  (and (member :resizable (window-style window)) t))

(defun (setf window-resizable-p) (resizable window)
  (update-style window :resizable resizable)
  resizable)

(defun window-decorated-p (window)
  "True when WINDOW has a title bar; a window without one is borderless."
  (and (member :titled (window-style window)) t))

(defun (setf window-decorated-p) (decorated window)
  (update-style window :titled decorated)
  decorated)

;;; Level: which windows a window stays above.

(defparameter *levels*
  '((:normal . 0)
    (:floating . 3)                     ; above normal windows: "always on top"
    (:status . 25)
    (:pop-up-menu . 101)
    (:screen-saver . 1000))
  "NSWindowLevel values by keyword.")

(defun window-level (window)
  "Return WINDOW's level: :NORMAL, :FLOATING (always on top), :STATUS,
:POP-UP-MENU, :SCREEN-SAVER, or an integer for any other level."
  (let ((level (on-window window (lambda () (send window "level" :long)))))
    (or (car (rassoc level *levels*)) level)))

(defun (setf window-level) (level window)
  (let ((value (if (integerp level)
                   level
                   (or (cdr (assoc level *levels*))
                       (error "Unknown window level ~S; expected an integer or one of ~S."
                              level (mapcar #'car *levels*))))))
    (on-window window (lambda () (send window "setLevel:" :long value :void))))
  level)

;;; Showing, hiding and focusing

(defun show-window (window)
  "Show WINDOW in front of the application's other windows, without taking
focus."
  (on-window window (lambda () (send window "orderFront:" :pointer (cffi:null-pointer) :void)))
  nil)

(defun hide-window (window)
  "Take WINDOW off the screen without closing it."
  (on-window window (lambda () (send window "orderOut:" :pointer (cffi:null-pointer) :void)))
  nil)

(defun window-visible-p (window)
  (on-window window (lambda () (send window "isVisible" :bool))))

(defun activate-application ()
  "Bring the application in front of other applications."
  (on-main
   (lambda ()
     (let ((app (app)))
       ;; -activate replaces -activateIgnoringOtherApps: from macOS 14.
       (if (responds-to-p app "activate")
           (send app "activate" :void)
           (send app "activateIgnoringOtherApps:" :bool t :void)))))
  nil)

(defun focus-window (window &key (activate t))
  "Make WINDOW the one that receives keyboard input. With ACTIVATE, the
application is also brought in front of other applications; without it the
window becomes the application's key window for when it is next active."
  (on-window window (lambda () (send window "makeKeyAndOrderFront:" :pointer (cffi:null-pointer) :void)))
  (when activate
    (activate-application))
  nil)

(defun window-focused-p (window)
  "True when WINDOW receives keyboard input: it is the key window of the
application and the application is active."
  (on-window window (lambda () (send window "isKeyWindow" :bool))))

;;; Minimizing, maximizing and full screen

(defun minimize-window (window)
  "Send WINDOW to the Dock."
  (on-window window (lambda () (send window "miniaturize:" :pointer (cffi:null-pointer) :void)))
  nil)

(defun restore-window (window)
  "Bring WINDOW back from the Dock."
  (on-window window (lambda () (send window "deminiaturize:" :pointer (cffi:null-pointer) :void)))
  nil)

(defun window-minimized-p (window)
  (on-window window (lambda () (send window "isMiniaturized" :bool))))

(defun window-maximized-p (window)
  "True when WINDOW is zoomed to fill its screen (the green button's
\"Zoom\", not full screen)."
  (on-window window (lambda () (send window "isZoomed" :bool))))

(defun (setf window-maximized-p) (maximized window)
  (on-window window
   (lambda ()
     (unless (eq (and maximized t) (send window "isZoomed" :bool))
       (send window "zoom:" :pointer (cffi:null-pointer) :void))))
  maximized)

(defconstant +style-full-screen+ (ash 1 14))
(defconstant +collection-full-screen-primary+ (ash 1 7))

(defun window-fullscreen-p (window)
  (on-window window (lambda () (logtest +style-full-screen+ (send window "styleMask" :unsigned-long)))))

(defun (setf window-fullscreen-p) (fullscreen window)
  "Enter or leave full screen, in a Space of its own. The change animates
and finishes a moment after this returns."
  (on-window window
   (lambda ()
     (unless (eq (and fullscreen t)
                 (logtest +style-full-screen+ (send window "styleMask" :unsigned-long)))
       (send window "setCollectionBehavior:"
             :unsigned-long (logior +collection-full-screen-primary+
                                    (send window "collectionBehavior" :unsigned-long))
             :void)
       (send window "toggleFullScreen:" :pointer (cffi:null-pointer) :void))))
  fullscreen)

;;; Opacity, background and transparency

(defun window-alpha (window)
  "WINDOW's opacity as a whole, from 0 (invisible) to 1."
  (on-window window (lambda () (send window "alphaValue" :double))))

(defun (setf window-alpha) (alpha window)
  (let ((alpha (float alpha 1d0)))
    (on-window window (lambda () (send window "setAlphaValue:" :double alpha :void))))
  alpha)

(defun window-background-color (window)
  "WINDOW's background color as a list of red, green, blue and alpha."
  (on-window window (lambda () (ns-color-components (send window "backgroundColor")))))

(defun (setf window-background-color) (color window)
  "Set WINDOW's background color: \"#rrggbb\", (r g b [a]) or :CLEAR."
  (color-components color)              ; check it here, in the caller
  (on-window window (lambda () (send window "setBackgroundColor:" :pointer (ns-color color) :void)))
  color)

(defun window-transparent-p (window)
  "True when WINDOW's background lets what is behind it show through."
  (on-window window (lambda () (not (send window "isOpaque" :bool)))))

(defun (setf window-transparent-p) (transparent window)
  "Make WINDOW's background see-through (its content and title bar are
drawn as before), or opaque again with the standard background."
  (on-window window
   (lambda ()
     (send window "setOpaque:" :bool (not transparent) :void)
     (send window "setBackgroundColor:"
           :pointer (if transparent
                        (send (find-class* "NSColor") "clearColor")
                        (send (find-class* "NSColor") "windowBackgroundColor"))
           :void)))
  transparent)

;;; Appearance: light or dark

(defparameter *appearances*
  '((:light . "NSAppearanceNameAqua")
    (:dark . "NSAppearanceNameDarkAqua")))

(defun window-appearance (window)
  "The appearance WINDOW is drawn in now: :LIGHT or :DARK. A window that
follows the system reports what the system currently uses."
  (on-window window
   (lambda ()
     (let ((name (lisp-string (send (send window "effectiveAppearance") "name"))))
       (if (search "Dark" name) :dark :light)))))

(defun (setf window-appearance) (appearance window)
  "Draw WINDOW in APPEARANCE, :LIGHT or :DARK, or follow the system with
:SYSTEM."
  (let ((name (unless (eq appearance :system)
                (or (cdr (assoc appearance *appearances*))
                    (error "Unknown appearance ~S; expected :LIGHT, :DARK or :SYSTEM."
                           appearance)))))
    (on-window window
     (lambda ()
       (send window "setAppearance:"
             :pointer (if name
                          (send (find-class* "NSAppearance") "appearanceNamed:"
                                :pointer (ns-string name))
                          (cffi:null-pointer))
             :void))))
  appearance)

;;; The title bar

(defun window-title-visible-p (window)
  (on-window window (lambda () (zerop (send window "titleVisibility" :long)))))

(defun (setf window-title-visible-p) (visible window)
  "Show or hide the title text; the title bar and its buttons stay."
  (on-window window (lambda () (send window "setTitleVisibility:" :long (if visible 0 1) :void)))
  visible)

(defun window-titlebar-transparent-p (window)
  (on-window window (lambda () (send window "titlebarAppearsTransparent" :bool))))

(defun (setf window-titlebar-transparent-p) (transparent window)
  "Draw the title bar without its own background. Together with the
:FULL-SIZE-CONTENT-VIEW style, the content then fills the whole window under
the title bar's buttons."
  (on-window window (lambda () (send window "setTitlebarAppearsTransparent:" :bool transparent :void)))
  transparent)

;;; Shadow and mouse events

(defun window-shadow-p (window)
  (on-window window (lambda () (send window "hasShadow" :bool))))

(defun (setf window-shadow-p) (shadow window)
  "Draw WINDOW with or without the drop shadow around its frame."
  (on-window window (lambda () (send window "setHasShadow:" :bool shadow :void)))
  shadow)

(defun window-ignores-mouse-p (window)
  (on-window window (lambda () (send window "ignoresMouseEvents" :bool))))

(defun (setf window-ignores-mouse-p) (ignore window)
  "Let clicks and scrolling pass through WINDOW to whatever is behind it,
as an overlay needs."
  (on-window window (lambda () (send window "setIgnoresMouseEvents:" :bool ignore :void)))
  ignore)
