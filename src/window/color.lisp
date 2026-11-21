;;;; Colors.
;;;;
;;;; A color is written as a CSS-style hex string ("#rgb", "#rrggbb" or
;;;; "#rrggbbaa"), a list (red green blue) or (red green blue alpha) of numbers
;;;; from 0 to 1, or :CLEAR. Colors read back are lists of four doubles, in
;;;; the sRGB color space.

(in-package #:cl-iris/window)

(defun parse-hex-color (string)
  (flet ((channel (start end)
           (let ((value (parse-integer string :start start :end end :radix 16)))
             (if (= (- end start) 1)
                 (/ (* value 17) 255d0)
                 (/ value 255d0)))))
    (case (length string)
      (4 (list (channel 1 2) (channel 2 3) (channel 3 4) 1d0))
      (7 (list (channel 1 3) (channel 3 5) (channel 5 7) 1d0))
      (9 (list (channel 1 3) (channel 3 5) (channel 5 7) (channel 7 9)))
      (t (error "Not a hex color: ~S" string)))))

(defun color-components (color)
  "Return COLOR as a list of red, green, blue and alpha from 0 to 1."
  (flet ((unit (x)
           (unless (and (realp x) (<= 0 x 1))
             (error "Color components are numbers from 0 to 1, not ~S." x))
           (float x 1d0)))
    (cond ((eq color :clear) (list 0d0 0d0 0d0 0d0))
          ((and (stringp color) (plusp (length color)) (char= #\# (char color 0)))
           (handler-case (parse-hex-color color)
             (parse-error () (error "Not a hex color: ~S" color))))
          ((and (listp color) (<= 3 (length color) 4))
           (mapcar #'unit (if (= 3 (length color)) (append color '(1)) color)))
          (t (error "Not a color: ~S; expected \"#rrggbb\", (r g b [a]) or :CLEAR." color)))))

(defun ns-color (color)
  "Return an autoreleased NSColor for COLOR."
  (destructuring-bind (red green blue alpha) (color-components color)
    (send (find-class* "NSColor") "colorWithSRGBRed:green:blue:alpha:"
          :double red :double green :double blue :double alpha)))

(defun ns-color-components (ns-color)
  "Return the sRGB red, green, blue and alpha of NS-COLOR as a list."
  (let ((srgb (send ns-color "colorUsingColorSpace:"
                    :pointer (send (find-class* "NSColorSpace") "sRGBColorSpace"))))
    (if (cffi:null-pointer-p srgb)
        (error "The color cannot be expressed in sRGB.")
        (list (send srgb "redComponent" :double)
              (send srgb "greenComponent" :double)
              (send srgb "blueComponent" :double)
              (send srgb "alphaComponent" :double)))))
