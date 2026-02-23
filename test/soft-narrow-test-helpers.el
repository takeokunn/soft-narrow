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
      ;; Initialize buffer-invisibility-spec to a list instead of t
      (setq buffer-invisibility-spec ())
      (erase-buffer)
      (dotimes (i lines)
        (insert (format "Line %d: Test content\n" (1+ i)))))
    buf))

(defun soft-narrow-test--cleanup-buffer (buf)
  "Kill buffer BUF if it exists."
  (when (buffer-live-p buf)
    (kill-buffer buf)))

(defun soft-narrow-test--count-invisible-chars (start end)
  "Count characters with invisible property between START and END."
  (let ((count 0)
        (pos start))
    (while (< pos end)
      (when (eq (get-text-property pos 'invisible) 'soft-narrow)
        (setq count (1+ count)))
      (setq pos (1+ pos)))
    count))

(provide 'soft-narrow-test-helpers)

;;; soft-narrow-test-helpers.el ends here
