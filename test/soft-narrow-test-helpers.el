;;; soft-narrow-test-helpers.el --- Test helper functions for soft-narrow tests -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>

;; This file is NOT part of GNU Emacs.

;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;;; Commentary:

;; Helper functions for soft-narrow test suite.

;;; Code:

(defun soft-narrow-test--create-test-buffer (lines)
  "Create a temporary buffer with LINES lines of test content.
Each line is numbered for easy reference."
  (let ((buf (generate-new-buffer " *soft-narrow-test*")))
    (with-current-buffer buf
      (erase-buffer)
      (dotimes (i lines)
        (insert (format "Line %d: Test content\n" (1+ i)))))
    buf))

(defun soft-narrow-test--cleanup-buffer (buf)
  "Kill buffer BUF if it exists and reset global mode state."
  (when (bound-and-true-p soft-narrow-mode)
    (soft-narrow-mode 0))
  (when (buffer-live-p buf)
    (kill-buffer buf)))

(defun soft-narrow-test--has-overlay-face-at (pos face)
  "Return non-nil if position POS has an overlay with FACE."
  (seq-some (lambda (ov)
              (and (overlay-get ov 'soft-narrow)
                   (eq (overlay-get ov 'face) face)))
            (overlays-at pos)))

(defmacro soft-narrow-test--with-buffer (lines var &rest body)
  "Bind VAR to a fresh LINES-line test buffer and run BODY in it.
The buffer is created via `soft-narrow-test--create-test-buffer' and
always cleaned up via `soft-narrow-test--cleanup-buffer', even if BODY
signals an error."
  (declare (indent 2) (debug t))
  `(let ((,var (soft-narrow-test--create-test-buffer ,lines)))
     (unwind-protect
         (with-current-buffer ,var
           ,@body)
       (soft-narrow-test--cleanup-buffer ,var))))

(provide 'soft-narrow-test-helpers)

;;; soft-narrow-test-helpers.el ends here
