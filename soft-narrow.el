;;; soft-narrow.el --- Narrow-to-region with more eye-candy -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>

;; Author: takeokunn <bararararatty@gmail.com>
;; Maintainer: takeokunn <bararararatty@gmail.com>
;; URL: https://github.com/takeokunn/soft-narrow
;; Version: 2.0.0
;; Keywords: faces convenience
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;;
;; This package was inspired by fancy-narrow.el by Artur Malabarba.
;; All code has been rewritten from scratch using Emacs 29.1+ APIs.
;;
;; soft-narrow
;; -----------
;;
;; Emacs package to imitate `narrow-to-region' with more eye-candy.
;;
;; Unlike `narrow-to-region', which completely hides text outside
;; the narrowed region, this package simply deemphasizes the text,
;; makes it readonly, and makes it unreachable.
;;
;; This leads to a much more natural feeling, where the region stays
;; static (instead of being brutally moved to a blank slate) and is
;; clearly highlighted with respect to the rest of the buffer.
;;
;; Simply call `soft-narrow-to-region' to see it in action.  To widen the
;; region again afterwards use `soft-narrow-widen'.
;;
;; Stackable Narrowing:
;; Successive calls to `soft-narrow-to-region' stack narrowing levels.
;; The visible region is the intersection of all narrowed regions.
;; Use `soft-narrow-widen' to pop back to the previous level.
;;
;; If you activate `soft-narrow-mode', the standard narrowing keys
;; (C-x n n, C-x n w, etc.) will use soft-narrow equivalents.
;;
;; Version 2.0.0 requires Emacs 29.1+ and uses modern APIs:
;; - cursor-intangible property for zero per-keystroke overhead
;; - Stackable narrowing with true intersection semantics
;; - No function advising or post-command-hook
;;
;; To customise the face used to deemphasize unreachable text, customise
;; `soft-narrow-blocked-face'.
;;
;; Note this is designed for user interaction.  For using within Lisp code,
;; the standard `narrow-to-region' is preferable, because soft-narrow
;; is susceptible to `inhibit-read-only' and some corner cases.

;;
;; This file is NOT part of GNU Emacs.
;;
;; This program is free software; you can redistribute it and/or
;; modify it under the terms of the GNU General Public License
;; as published by the Free Software Foundation; either version 3
;; of the License, or (at your option) any later version.
;;
;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.
;;

;;; Code:

;; Org-mode variables used in org narrowing functions
(defvar org-element-greater-elements)

;; Org-mode macro (needed at compile time for macro expansion)
(eval-when-compile
  (require 'org-macs nil t))

;; Org-mode function declarations
(declare-function org-between-regexps-p "org" (start-re end-re &optional lim-up lim-down))
(declare-function org-element-at-point "org-element" ())
(declare-function org-element-property "org-element" (property element))
(declare-function org-back-to-heading "org" (&optional invisible-ok))
(declare-function org-end-of-subtree "org" (&optional invisible-ok to-heading))
(declare-function org-at-heading-p "org" (&optional ignored))
(declare-function org-get-limited-outline-regexp "org" (&optional arg1))

(defgroup soft-narrow nil
  "Customization group for soft-narrow."
  :prefix "soft-narrow-"
  :group 'editing)

;;; Stack Data Structure

(defvar-local soft-narrow--stack nil
  "Stack of narrowing frames for LIFO semantics.
Each frame is a cons (START-MARKER . END-MARKER).")

(defvar-local soft-narrow--overlays nil
  "List of overlays for face properties in blocked regions.")

;;;###autoload
(defun soft-narrow-active-p ()
  "Return non-nil if the current buffer is soft-narrowed."
  (and (boundp 'soft-narrow--stack)
       soft-narrow--stack))

(defun soft-narrow--compute-intersection ()
  "Compute intersection of all frames in the narrowing stack.
Return (START . END) for valid intersection, or nil if no valid intersection."
  (when soft-narrow--stack
    (let ((first (car soft-narrow--stack)))
      (named-let loop ((frames (cdr soft-narrow--stack))
                       (max-start (marker-position (car first)))
                       (min-end (marker-position (cdr first))))
        (if (null frames)
            (cons max-start min-end)
          (let ((new-start (max max-start (marker-position (car (car frames)))))
                (new-end (min min-end (marker-position (cdr (car frames))))))
            (if (>= new-start new-end)
                nil
              (loop (cdr frames) new-start new-end))))))))

(defun soft-narrow--delete-overlays ()
  "Delete all soft-narrow overlays and clear the list."
  (mapc #'delete-overlay soft-narrow--overlays)
  (setq soft-narrow--overlays nil))

(defun soft-narrow--create-overlays (start end)
  "Create overlays for blocked regions outside START..END.
Overlays carry only the `face' property for visual deemphasis."
  (when (> start (point-min))
    (let ((ov (make-overlay (point-min) start nil nil nil)))
      (overlay-put ov 'face 'soft-narrow-blocked-face)
      (overlay-put ov 'soft-narrow t)
      (push ov soft-narrow--overlays)))
  (when (< end (point-max))
    (let ((ov (make-overlay end (point-max) nil nil t)))
      (overlay-put ov 'face 'soft-narrow-blocked-face)
      (overlay-put ov 'soft-narrow t)
      (push ov soft-narrow--overlays))))

(defun soft-narrow--apply-properties ()
  "Apply narrowing properties based on current intersection.
Blocked regions get overlay face for visual deemphasis, plus
text properties for cursor restriction and read-only protection."
  (soft-narrow--delete-overlays)
  (if-let* ((intersection (soft-narrow--compute-intersection))
             (l (car intersection))
             (r (cdr intersection)))
      (progn
        (when (fboundp 'cursor-intangible-mode)
          (unless (bound-and-true-p cursor-intangible-mode)
            (cursor-intangible-mode 1)))
        (with-silent-modifications
          (remove-list-of-text-properties
           (point-min) (point-max)
           '(cursor-intangible read-only front-sticky rear-nonsticky))
          (add-text-properties (point-min) l
                               '(cursor-intangible t read-only t
                                 rear-nonsticky (cursor-intangible)
                                 front-sticky (cursor-intangible)))
          (add-text-properties r (point-max)
                               '(cursor-intangible t read-only t)))
        (soft-narrow--create-overlays l r))
    ;; No valid intersection - clear all properties
    (with-silent-modifications
      (remove-list-of-text-properties
       (point-min) (point-max)
       '(cursor-intangible read-only front-sticky rear-nonsticky))
      (when (bound-and-true-p cursor-intangible-mode)
        (cursor-intangible-mode -1)))))

;;;###autoload
(defun soft-narrow-to-region (start end)
  "Like `narrow-to-region', except it still displays the unreachable text.

START and END define the region to narrow to.

Unlike `narrow-to-region', which completely hides text outside
the narrowed region, this function simply deemphasizes the text,
makes it readonly, and makes it unreachable.

This leads to a much more natural feeling, where the region stays
static (instead of moving up to hide the text above) and is
clearly highlighted with respect to the rest of the buffer.

Stackable Narrowing:
Successive calls to `soft-narrow-to-region' stack rather than widen.
The visible region is the intersection of all narrowed regions.

To widen the region again afterwards use `soft-narrow-widen'."
  (interactive "r")
  (unless (bound-and-true-p soft-narrow-mode) (soft-narrow-mode 1))
  ;; Validate and normalize bounds
  (let ((start (max (min start end) (point-min)))
        (end (min (max start end) (point-max))))
    (push (cons (copy-marker start nil)
                (copy-marker end t))
          soft-narrow--stack)
    (soft-narrow--apply-properties)
    (deactivate-mark)))

;;;###autoload
(defun soft-narrow-widen ()
  "Pop one level from narrowing stack, returning to previous narrow.

If no narrowing is active, this function does nothing harmlessly."
  (interactive)
  ;; Pop one level from stack
  (when soft-narrow--stack
    (let ((frame (pop soft-narrow--stack)))
      ;; Clean up markers from removed frame
      (set-marker (car frame) nil)
      (set-marker (cdr frame) nil)))
  ;; Reapply properties based on new stack state
  (soft-narrow--apply-properties))

(defcustom soft-narrow-lighter " *"
  "Lighter used in the mode-line while mode is active."
  :type 'string
  :group 'soft-narrow
  :package-version '(soft-narrow . "2.0.0"))

(defvar-keymap soft-narrow-mode-map
  :doc "Keymap for `soft-narrow-mode'."
  "C-x n b" #'soft-narrow-org-to-block
  "C-x n d" #'soft-narrow-to-defun
  "C-x n e" #'soft-narrow-org-to-element
  "C-x n n" #'soft-narrow-to-region
  "C-x n p" #'soft-narrow-to-page
  "C-x n s" #'soft-narrow-org-to-subtree
  "C-x n w" #'soft-narrow-widen)

;;;###autoload
(define-minor-mode soft-narrow-mode
  "Minor mode that binds to soft-narrow functions.

The keys used are the same used by the standard Emacs functions.
Binds that are replaced are:
   `widen'
   `narrow-to-region'
   `narrow-to-defun'
   `narrow-to-page'
   `org-narrow-to-block'
   `org-narrow-to-element'
   `org-narrow-to-subtree'

Stackable Narrowing:
Successive narrowing creates intersection of all narrowed regions.
Use `soft-narrow-widen' to pop back to previous narrow levels."
  :lighter (:eval (when (soft-narrow-active-p) soft-narrow-lighter))
  :keymap soft-narrow-mode-map
  :global t
  :group 'soft-narrow
  (unless soft-narrow-mode
    (dolist (buf (buffer-list))
      (with-current-buffer buf
        (while (soft-narrow-active-p)
          (soft-narrow-widen))))))

(defface soft-narrow-blocked-face
  '((((background light)) :foreground "Grey70")
    (((background dark)) :foreground "Grey30"))
  "Face used on blocked text."
  :group 'soft-narrow)

;;; Narrowing Commands:
;;
;; The following commands are adapted from their standard Emacs
;; counterparts, using `soft-narrow-to-region' instead of
;; `narrow-to-region'.

;;;###autoload
(defun soft-narrow-org-to-block ()
  "Like `org-narrow-to-block', except using `soft-narrow-to-region'."
  (interactive)
  (let ((case-fold-search t))
    (if-let* ((blockp (org-between-regexps-p "^[ \t]*#\\+begin_.*"
                                              "^[ \t]*#\\+end_.*")))
        (soft-narrow-to-region (car blockp) (cdr blockp))
      (user-error "Not in a block"))))

;;;###autoload
(defun soft-narrow-to-defun (&optional _arg)
  "Like `narrow-to-defun', except using `soft-narrow-to-region'."
  (interactive)
  (save-excursion
    ;; Widen first so defun boundaries can be found regardless of
    ;; current narrowing state (mirrors `narrow-to-defun' behavior).
    (widen)
    (let ((opoint (point))
          beg end)
      (let ((here (point)))
        (unless (eolp)
          (forward-char))
        (beginning-of-defun)
        (when (< (point) here)
          (goto-char here)
          (beginning-of-defun)))
      (setq beg (point))
      (end-of-defun)
      (setq end (point))
      (while (looking-at "^\n")
        (forward-line 1))
      (unless (> (point) opoint)
        ;; beginning-of-defun moved back one defun
        ;; so we got the wrong one.
        (goto-char opoint)
        (end-of-defun)
        (setq end (point))
        (beginning-of-defun)
        (setq beg (point)))
      (goto-char end)
      (re-search-backward "^\n" (- (point) 1) t)
      (soft-narrow-to-region beg end))))

;;;###autoload
(defun soft-narrow-org-to-element ()
  "Like `org-narrow-to-element', except using `soft-narrow-to-region'."
  (interactive)
  (let ((elem (org-element-at-point)))
    (pcase (car elem)
      ((and type (guard (and (not (eq type 'headline))
                             (memq type org-element-greater-elements))))
       (soft-narrow-to-region
        (org-element-property :contents-begin elem)
        (org-element-property :contents-end elem)))
      (_
       (soft-narrow-to-region
        (org-element-property :begin elem)
        (org-element-property :end elem))))))

;;;###autoload
(defun soft-narrow-to-page (&optional arg)
  "Like `narrow-to-page', except using `soft-narrow-to-region'.
Optional prefix ARG specifies which page to narrow to."
  (interactive "P")
  (setq arg (if arg (prefix-numeric-value arg) 0))
  (save-excursion
    (widen)
    (if (> arg 0)
        (forward-page arg)
      (if (< arg 0)
          (let ((adjust 0)
                (opoint (point)))
            ;; If we are not now at the beginning of a page,
            ;; move back one extra time, to get to the start of this page.
            (save-excursion
              (beginning-of-line)
              (or (and (looking-at page-delimiter)
                       (eq (match-end 0) opoint))
                  (setq adjust 1)))
            (forward-page (- arg adjust)))))
    ;; Find end of the page.
    (set-match-data nil)
    (forward-page)
    ;; If we stopped due to end of buffer, stay there.
    ;; If we stopped after a page delimiter, put end of restriction
    ;; at the beginning of that line.
    ;; Before checking the match that was found,
    ;; verify that forward-page actually set match data.
    (when (and (match-beginning 0)
               (save-excursion
                 (goto-char (match-beginning 0))
                 (looking-at page-delimiter)))
      (goto-char (match-beginning 0)))
    (let ((end (point)))
      ;; Find top of the page.
      (forward-page -1)
      ;; If we found beginning of buffer, stay there.
      ;; If extra text follows page delimiter on same line, include it.
      ;; Otherwise, show text starting with following line.
      (when (and (eolp) (not (bobp)))
        (forward-line 1))
      (soft-narrow-to-region (point) end))))

;;;###autoload
(defun soft-narrow-org-to-subtree ()
  "Like `org-narrow-to-subtree', except using `soft-narrow-to-region'."
  (interactive)
  (save-excursion
    (save-match-data
      (org-with-limited-levels
       (soft-narrow-to-region
        (progn (org-back-to-heading t) (point))
        (progn (org-end-of-subtree t t)
               (if (and (org-at-heading-p) (not (eobp))) (backward-char 1))
               (point)))))))

(provide 'soft-narrow)
;;; soft-narrow.el ends here
