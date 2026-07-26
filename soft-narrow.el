;;; soft-narrow.el --- Narrow-to-region with more eye-candy -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>

;; Author: takeokunn <bararararatty@gmail.com>
;; Maintainer: takeokunn <bararararatty@gmail.com>
;; URL: https://github.com/takeokunn/soft-narrow
;; Version: 1.2.1
;; Keywords: faces convenience
;; Package-Requires: ((emacs "29.1"))

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
;;
;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

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
;; This package requires Emacs 29.1+ and uses modern APIs:
;; - cursor-intangible property for minimal per-keystroke overhead
;; - Stackable narrowing with true intersection semantics
;; - No function advising; buffer-local pre/post-command-hooks for boundary enforcement
;;
;; To customise the face used to deemphasize unreachable text, customise
;; `soft-narrow-blocked-face'.
;;
;; Note this is designed for user interaction.  For using within Lisp code,
;; the standard `narrow-to-region' is preferable, because soft-narrow
;; is susceptible to `inhibit-read-only' and some corner cases.
;;
;; Restriction model and its limits:
;; soft-narrow keeps `point-min'/`point-max' pointed at the whole buffer
;; so the surrounding text stays visible.  It therefore does NOT scope
;; commands that scan the accessible buffer -- org export, `count-words',
;; `mark-whole-buffer', `sort-lines', `fill-region', babel execution and
;; the like still see the entire buffer.  This is inherent: Emacs ties
;; the accessible portion to the displayed portion, so a purely visual
;; narrowing cannot automatically restrict such commands.  When you need
;; an operation scoped to the visible region, wrap it in
;; `soft-narrow-with-restriction' (which applies a genuine
;; `narrow-to-region' for the duration) or run it via the interactive
;; `soft-narrow-execute' (C-x n x).  `soft-narrow-org-export-dispatch' is
;; a ready-made wrapper for org export.
;;
;; The `soft-narrow-org-to-*' commands work in `org-mode' buffers and
;; require org-mode to be loaded at runtime; org-mode is not declared in
;; `Package-Requires' because it ships with Emacs and is loaded lazily.

;;; Code:

;; Forward declaration to suppress byte-compiler warnings.
;; The actual value is set by org-element.el.
(progn
  (with-no-warnings
    (defvar org-element-greater-elements))
  (require 'cursor-sensor))

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
(declare-function org-export-dispatch "ox" (&optional arg))

(defgroup soft-narrow nil
  "Customization group for soft-narrow."
  :prefix "soft-narrow-"
  :group 'editing)

;;; Stack Data Structure

(defvar-local soft-narrow--stack nil
  "Stack of narrowing frames for LIFO semantics.
Each frame is a cons (START-MARKER . END-MARKER).")

(defvar-local soft-narrow--before-overlay nil
  "Persistent overlay covering blocked text before the narrowed region.")

(defvar-local soft-narrow--after-overlay nil
  "Persistent overlay covering blocked text after the narrowed region.")

(defvar-local soft-narrow--cached-intersection nil
  "Cached result of `soft-narrow--compute-intersection`.
A cons (START . END) while active, including zero-width intersections,
and nil otherwise.  Refreshed after edits because stack markers move.")

(defvar-local soft-narrow--cached-modification-tick nil
  "Value of `buffer-chars-modified-tick` for the cached intersection.")

(defvar-local soft-narrow--owns-cursor-intangible nil
  "Non-nil if soft-narrow enabled `cursor-intangible-mode' in this buffer.
Prevents `soft-narrow-widen' from disabling a mode the user or another
package enabled independently.  External toggles are detected via
`cursor-intangible-mode-hook' and reset ownership immediately.")

(defvar-local soft-narrow--toggling-cursor-intangible nil
  "Non-nil while soft-narrow is enabling/disabling `cursor-intangible-mode'.
Suppresses the `cursor-intangible-mode-hook' ownership-reset to avoid
false positives.")

(defun soft-narrow--on-cursor-intangible-mode-change ()
  "Detect external toggling of `cursor-intangible-mode'.
Added to `cursor-intangible-mode-hook' while narrowed.  When the mode is
turned off and soft-narrow previously owned it, release ownership
immediately so that subsequent user re-enables are not incorrectly
disabled on final widen."
  (unless soft-narrow--toggling-cursor-intangible
    (when (and soft-narrow--owns-cursor-intangible
               (not (bound-and-true-p cursor-intangible-mode)))
      (setq soft-narrow--owns-cursor-intangible nil))))

;;;###autoload
(defun soft-narrow-active-p ()
  "Return non-nil if the current buffer is soft-narrowed."
  soft-narrow--stack)

;;;###autoload
(defun soft-narrow-region-bounds ()
  "Return the visible soft-narrow region as a cons (START . END).
Return nil only when the buffer is not soft-narrowed.  Empty and disjoint
intersections are represented by equal START and END positions."
  (soft-narrow--sync-intersection))

(defun soft-narrow--compute-intersection ()
  "Compute the normalized intersection of all narrowing frames.
Return nil for an empty stack.  Empty or disjoint intersections are
represented as a zero-width cons so an active stack always has bounds."
  (when soft-narrow--stack
    (let ((max-start (point-min))
          (min-end (point-max)))
      (dolist (frame soft-narrow--stack)
        (setq max-start (max max-start (marker-position (car frame)))
              min-end (min min-end (marker-position (cdr frame)))))
      (cons max-start (max max-start min-end)))))

(defun soft-narrow--ensure-overlays ()
  "Ensure the two buffer-owned blocking overlays exist."
  (unless (overlayp soft-narrow--before-overlay)
    (setq soft-narrow--before-overlay (make-overlay 1 1))
    (overlay-put soft-narrow--before-overlay (quote soft-narrow) t))
  (unless (overlayp soft-narrow--after-overlay)
    (setq soft-narrow--after-overlay (make-overlay 1 1))
    (overlay-put soft-narrow--after-overlay (quote soft-narrow) t))
  (dolist (overlay (list soft-narrow--before-overlay
                         soft-narrow--after-overlay))
    (overlay-put overlay (quote face) (quote soft-narrow-blocked-face))
    (overlay-put overlay (quote read-only) t)
    (overlay-put overlay (quote cursor-intangible) t)
    (overlay-put overlay (quote modification-hooks)
                 (list (function soft-narrow--prevent-modification)))))

(defun soft-narrow--show-overlays (start end)
  "Position persistent overlays to block text outside START..END."
  (soft-narrow--ensure-overlays)
  (if (= start end)
      (progn
        (move-overlay soft-narrow--before-overlay (point-min) (point-max))
        (move-overlay soft-narrow--after-overlay (point-min) (point-max)))
    (if (> start (point-min))
        (move-overlay soft-narrow--before-overlay (point-min) start)
      (move-overlay soft-narrow--before-overlay 1 1))
    (if (< end (point-max))
        (move-overlay soft-narrow--after-overlay end (point-max))
      (move-overlay soft-narrow--after-overlay 1 1)))
  (overlay-put soft-narrow--before-overlay (quote insert-in-front-hooks)
               (and (< (overlay-start soft-narrow--before-overlay)
                       (overlay-end soft-narrow--before-overlay))
                    (list (function soft-narrow--prevent-modification))))
  (overlay-put soft-narrow--after-overlay (quote insert-behind-hooks)
               (and (< (overlay-start soft-narrow--after-overlay)
                       (overlay-end soft-narrow--after-overlay))
                    (list (function soft-narrow--prevent-modification)))))


(defun soft-narrow--prevent-modification (_overlay after &rest _arguments)
  "Reject a blocked change unless AFTER or read-only inhibition permits it."
  (unless (or after inhibit-read-only)
    (signal (quote text-read-only) nil)))

(defun soft-narrow--destroy-overlays ()
  "Delete persistent overlays and clear buffer-local references."
  (when (overlayp soft-narrow--before-overlay)
    (delete-overlay soft-narrow--before-overlay)
    (setq soft-narrow--before-overlay nil))
  (when (overlayp soft-narrow--after-overlay)
    (delete-overlay soft-narrow--after-overlay)
    (setq soft-narrow--after-overlay nil)))


(defun soft-narrow--free-frame (frame)
  "Detach both markers owned by FRAME."
  (when (markerp (car frame))
    (set-marker (car frame) nil))
  (when (markerp (cdr frame))
    (set-marker (cdr frame) nil)))

(defun soft-narrow--free-stack ()
  "Detach all stack markers and clear the active narrowing state."
  (let ((frames soft-narrow--stack))
    (setq soft-narrow--stack nil
          soft-narrow--cached-intersection nil
          soft-narrow--cached-modification-tick nil)
    (dolist (frame frames)
      (soft-narrow--free-frame frame))))

(defun soft-narrow--cleanup ()
  "Release all buffer-local narrowing state without touching buffer text."
  (unwind-protect
      (progn
        (soft-narrow--free-stack)
        (when (and soft-narrow--owns-cursor-intangible
                   (bound-and-true-p cursor-intangible-mode))
          (soft-narrow--set-cursor-intangible-ownership nil)))
    (setq soft-narrow--owns-cursor-intangible nil)
    (remove-hook (quote cursor-intangible-mode-hook)
                 (function soft-narrow--on-cursor-intangible-mode-change) t)
    (remove-hook (quote pre-command-hook)
                 (function soft-narrow--guard-boundary) t)
    (remove-hook (quote post-command-hook)
                 (function soft-narrow--clamp-point) t)
    (remove-hook (quote after-change-functions)
                 (function soft-narrow--refresh-intersection) t)
    (remove-hook (quote change-major-mode-hook)
                 (function soft-narrow--cleanup) t)
    (soft-narrow--destroy-overlays)))

(defun soft-narrow--set-cursor-intangible-ownership (enable)
  "Toggle `cursor-intangible-mode' per ENABLE while tracking ownership.
Binds `soft-narrow--toggling-cursor-intangible' so
`soft-narrow--on-cursor-intangible-mode-change' does not mistake this
internal toggle for an external one."
  (let ((soft-narrow--toggling-cursor-intangible t))
    (setq soft-narrow--owns-cursor-intangible enable)
    (cursor-intangible-mode (if enable 1 -1))))

(defun soft-narrow--sync-intersection ()
  "Refresh and return the cached intersection when shared text changed.
The modification tick is shared by base and indirect buffers, so this also
catches edits whose `after-change-functions` ran in a sibling buffer."
  (let ((tick (buffer-chars-modified-tick)))
    (unless (equal tick soft-narrow--cached-modification-tick)
      (setq soft-narrow--cached-intersection
            (soft-narrow--compute-intersection)
            soft-narrow--cached-modification-tick tick)))
  soft-narrow--cached-intersection)

(defun soft-narrow--apply-properties ()
  "Apply overlay-based narrowing for the current stack intersection."
  (let ((intersection (soft-narrow--compute-intersection)))
    (setq soft-narrow--cached-intersection intersection
          soft-narrow--cached-modification-tick
          (buffer-chars-modified-tick))
    (if intersection
        (let ((l (car intersection))
              (r (cdr intersection)))
          (unless (bound-and-true-p cursor-intangible-mode)
            (soft-narrow--set-cursor-intangible-ownership t))
          (add-hook (quote cursor-intangible-mode-hook)
                    (function soft-narrow--on-cursor-intangible-mode-change) nil t)
          (soft-narrow--show-overlays l r)
          (add-hook (quote pre-command-hook)
                    (function soft-narrow--guard-boundary) nil t)
          (add-hook (quote post-command-hook)
                    (function soft-narrow--clamp-point) 10 t)
          (add-hook (quote after-change-functions)
                    (function soft-narrow--refresh-intersection) nil t)
          (add-hook (quote change-major-mode-hook)
                    (function soft-narrow--cleanup) nil t))
      (soft-narrow--cleanup))))

(defun soft-narrow--guard-boundary ()
  "Suppress movement commands that would leave the narrowed region.
Runs in `pre-command-hook` so the cursor never enters blocked areas,
preventing visual flicker from the two-phase post-command correction."
  (when-let* ((intersection (soft-narrow--sync-intersection))
              (l (car intersection))
              (r (cdr intersection)))
    (cond
     ((and (>= (point) (1- r))
           (memq this-command
                 (quote (next-line forward-char forward-paragraph
                         scroll-up-command end-of-buffer))))
      (setq this-command (function ignore)))
     ((and (<= (point) l)
           (memq this-command
                 (quote (previous-line backward-char backward-paragraph
                         scroll-down-command beginning-of-buffer))))
      (setq this-command (function ignore))))))

(defun soft-narrow--clamp-point ()
  "Clamp point to the narrowed region boundaries.
Prevents the cursor from resting inside the visually blocked overlay areas.
Added to `post-command-hook` as a buffer-local hook."
  (when-let* ((intersection (soft-narrow--sync-intersection))
              (l (car intersection))
              (r (cdr intersection)))
    (cond
     ((< (point) l) (goto-char l))
     ((>= (point) r) (goto-char (max l (1- r)))))))

(defun soft-narrow--refresh-intersection (beg end old-length)
  "Refresh the cached intersection and blocking overlays after an edit.
BEG and END delimit the changed text after the edit; OLD-LENGTH is its length
before the edit.  Use marker-tracked geometry for edits strictly inside the
cached intersection, and recompute at boundaries or when the cache is stale."
  (let* ((cached soft-narrow--cached-intersection)
         (l (car-safe cached))
         (r (cdr-safe cached))
         (delta (- (- end beg) old-length))
         (new-r (and r (+ r delta)))
         (fast-path
          (and cached
               (overlayp soft-narrow--before-overlay)
               (overlayp soft-narrow--after-overlay)
               (> beg l)
               (< (+ beg old-length) r)
               (if (= l (point-min))
                   (= (overlay-start soft-narrow--before-overlay)
                      (overlay-end soft-narrow--before-overlay))
                 (= (overlay-end soft-narrow--before-overlay) l))
               (if (= new-r (point-max))
                   (= (overlay-start soft-narrow--after-overlay)
                      (overlay-end soft-narrow--after-overlay))
                 (= (overlay-start soft-narrow--after-overlay) new-r)))))
    (if fast-path
        (setq soft-narrow--cached-intersection (cons l new-r)
              soft-narrow--cached-modification-tick
              (buffer-chars-modified-tick))
      (when-let* ((intersection (soft-narrow--compute-intersection)))
        (setq soft-narrow--cached-intersection intersection
              soft-narrow--cached-modification-tick
              (buffer-chars-modified-tick))
        (let ((inhibit-modification-hooks t))
          (soft-narrow--show-overlays
           (car intersection) (cdr intersection)))))))

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
  ;; Validate and normalize bounds
  (let* ((lower (min start end))
         (upper (max start end))
         (start (max lower (point-min)))
         (end (min upper (point-max)))
         (previous-stack soft-narrow--stack)
         (previous-intersection soft-narrow--cached-intersection)
         (previous-cursor-intangible-mode
          (bound-and-true-p cursor-intangible-mode))
         (previous-cursor-intangible-ownership
          soft-narrow--owns-cursor-intangible)
         (previous-cursor-hook (copy-tree cursor-intangible-mode-hook))
         (previous-pre-hook (copy-tree pre-command-hook))
         (previous-post-hook (copy-tree post-command-hook))
         (previous-change-hook (copy-tree after-change-functions))
         (previous-major-mode-hook (copy-tree change-major-mode-hook))
         (frame (cons (copy-marker start nil) (copy-marker end t)))
         completed)
    (unless (bound-and-true-p soft-narrow-mode)
      (soft-narrow-mode 1))
    (setq soft-narrow--stack (cons frame previous-stack))
    (unwind-protect
	(progn
          (soft-narrow--apply-properties)
          (soft-narrow--clamp-point)
          (prog1 (deactivate-mark)
            (setq completed t)))
      (unless completed
	(setq soft-narrow--stack previous-stack)
	(condition-case nil
            (soft-narrow--free-frame frame)
          (error nil))
	(condition-case nil
            (if previous-stack
		(soft-narrow--apply-properties)
              (soft-narrow--cleanup))
          (error
           (setq soft-narrow--cached-intersection previous-intersection
                 soft-narrow--cached-modification-tick nil)))
	(unwind-protect
            (condition-case nil
		(let ((cursor-intangible-mode-hook nil)
                      (soft-narrow--toggling-cursor-intangible t))
                  (cursor-intangible-mode
                   (if previous-cursor-intangible-mode 1 -1)))
              (error nil))
          (progn
            (set (quote cursor-intangible-mode)
                 previous-cursor-intangible-mode)
            (setq soft-narrow--owns-cursor-intangible
                  previous-cursor-intangible-ownership
                  cursor-intangible-mode-hook previous-cursor-hook
                  pre-command-hook previous-pre-hook
                  post-command-hook previous-post-hook
                  after-change-functions previous-change-hook
                  change-major-mode-hook previous-major-mode-hook)))))))

;;;###autoload
(defun soft-narrow-widen ()
  "Pop one narrowing level and restore the previous intersection.
If no narrowing is active, do nothing."
  (interactive)
  (when soft-narrow--stack
    (soft-narrow--free-frame (pop soft-narrow--stack))
    (if soft-narrow--stack
        (soft-narrow--apply-properties)
      (soft-narrow--cleanup))))

(defcustom soft-narrow-lighter " *"
  "Lighter used in the mode-line while mode is active."
  :type 'string
  :group 'soft-narrow
  :package-version '(soft-narrow . "1.1.0"))

(defvar-keymap soft-narrow-mode-map
  :doc "Keymap for `soft-narrow-mode'."
  "C-x n b" #'soft-narrow-org-to-block
  "C-x n d" #'soft-narrow-to-defun
  "C-x n e" #'soft-narrow-org-to-element
  "C-x n n" #'soft-narrow-to-region
  "C-x n p" #'soft-narrow-to-page
  "C-x n s" #'soft-narrow-org-to-subtree
  "C-x n w" #'soft-narrow-widen
  "C-x n x" #'soft-narrow-execute)

;;;###autoload
(define-minor-mode soft-narrow-mode
  "Minor mode that binds to soft-narrow functions.

The keys used are the same used by the standard Emacs functions.
Successive narrowing creates the intersection of all narrowed regions;
`soft-narrow-widen` pops one level from the stack."
  :lighter (:eval (when (soft-narrow-active-p) soft-narrow-lighter))
  :keymap soft-narrow-mode-map
  :global t
  :group (quote soft-narrow)
  (unless soft-narrow-mode
    (let (first-error)
      (dolist (buf (buffer-list))
        (when (buffer-live-p buf)
          (with-current-buffer buf
            (when (or soft-narrow--stack
                      (overlayp soft-narrow--before-overlay)
                      (overlayp soft-narrow--after-overlay)
                      soft-narrow--owns-cursor-intangible)
              (condition-case error-data
                  (soft-narrow--cleanup)
                (error
                 (unless first-error
                   (setq first-error error-data))))))))
      (when first-error
        (signal (car first-error) (cdr first-error))))))

(defface soft-narrow-blocked-face
  '((((background light)) :foreground "Grey70")
    (((background dark)) :foreground "Grey30"))
  "Face used on blocked text."
  :group 'soft-narrow)

;;; Real-Restriction Escape Hatch:
;;
;; soft-narrow intentionally leaves `point-min'/`point-max' pointing at
;; the whole buffer so the surrounding text stays visible.  The cost is
;; that commands which scan the accessible buffer -- org export,
;; `count-words', `mark-whole-buffer', `sort-lines', `fill-region',
;; babel execution, and so on -- ignore the soft narrowing and operate
;; on the entire buffer.  This is inherent: Emacs ties the accessible
;; portion to the displayed portion, so a purely visual narrowing cannot
;; automatically scope such commands.
;;
;; `soft-narrow-with-restriction' bridges the gap on demand by applying a
;; genuine `narrow-to-region' to the soft-narrow bounds for the dynamic
;; extent of its body, then restoring the previous restriction.  Use it
;; (or the interactive `soft-narrow-execute') to scope any buffer-wide
;; operation to the visible region.

(defmacro soft-narrow-with-restriction (&rest body)
  "Run BODY with a real restriction to the current soft-narrow region.
soft-narrow deliberately keeps `point-min'/`point-max' at the whole
buffer so surrounding text stays visible; as a result, commands that
scan the accessible buffer (org export, `count-words',
`mark-whole-buffer', sorting, filling, ...) ignore the soft narrowing.
Wrapping such an operation in this macro applies a genuine
`narrow-to-region' to the soft-narrow bounds for the dynamic extent of
BODY (restored afterwards via `save-restriction'), so the operation is
scoped exactly to the visible region.  When the buffer is not
soft-narrowed, BODY runs unchanged."
  (declare (indent 0) (debug t))
  (let ((bounds (make-symbol "bounds")))
    `(let ((,bounds (soft-narrow-region-bounds)))
       (save-restriction
         (when ,bounds
           (narrow-to-region (car ,bounds) (cdr ,bounds)))
         ,@body))))

;;;###autoload
(defun soft-narrow-execute (command)
  "Read COMMAND and run it scoped to the soft-narrow region.
COMMAND is read interactively with completion and invoked via
`call-interactively' inside `soft-narrow-with-restriction', so
buffer-scanning commands (org export, `count-words',
`mark-whole-buffer', ...) act on the soft-narrowed region even though
soft-narrow does not restrict `point-min'/`point-max'.  Bound to
\\<soft-narrow-mode-map>\\[soft-narrow-execute] in `soft-narrow-mode'."
  (interactive
   (list (read-command
          (if (soft-narrow-active-p)
              "Run within soft-narrow region: "
            "Run command (no soft-narrowing active): "))))
  (soft-narrow-with-restriction
    (call-interactively command)))

;;;###autoload
(defun soft-narrow-org-export-dispatch ()
  "Like `org-export-dispatch', but scoped to the soft-narrow region.
Runs `org-export-dispatch' inside `soft-narrow-with-restriction' so that
export only sees the soft-narrowed region instead of the whole buffer."
  (interactive)
  (require 'org nil t)
  (require 'ox nil t)
  (soft-narrow-with-restriction
    (call-interactively 'org-export-dispatch)))

;;; Narrowing Commands:
;;
;; The following commands are adapted from their standard Emacs
;; counterparts, using `soft-narrow-to-region' instead of
;; `narrow-to-region'.

;;;###autoload
(defun soft-narrow-org-to-block ()
  "Like `org-narrow-to-block', except using `soft-narrow-to-region'."
  (interactive)
  (require 'org nil t)
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
    ;; Widen inside `save-restriction' so defun boundaries can be found
    ;; regardless of any active restriction, while preserving that
    ;; restriction (a bare `widen' would permanently discard a user's
    ;; real `narrow-to-region').
    (save-restriction
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
        (soft-narrow-to-region beg end)))))

;;;###autoload
(defun soft-narrow-org-to-element ()
  "Like `org-narrow-to-element', except using `soft-narrow-to-region'."
  (interactive)
  (require 'org nil t)
  (require 'org-element nil t)
  (let ((elem (org-element-at-point)))
    (pcase (car elem)
      ((and type (guard (and (not (eq type 'headline))
                             (memq type org-element-greater-elements)
                             ;; An empty greater element (e.g. an empty
                             ;; block or drawer) has no contents; its
                             ;; :contents-begin/:contents-end are nil.
                             ;; Guard here so we fall through to the
                             ;; :begin/:end branch instead of passing nil
                             ;; to `soft-narrow-to-region'.
                             (org-element-property :contents-begin elem)
                             (org-element-property :contents-end elem))))
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
    ;; Widen inside `save-restriction' so page boundaries can be found
    ;; regardless of any active restriction, while preserving that
    ;; restriction (a bare `widen' would permanently discard a user's
    ;; real `narrow-to-region').
    (save-restriction
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
        (soft-narrow-to-region (point) end)))))

;;;###autoload
(defun soft-narrow-org-to-subtree ()
  "Like `org-narrow-to-subtree', except using `soft-narrow-to-region'."
  (interactive)
  (require 'org nil t)
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
