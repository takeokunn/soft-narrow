;;; soft-narrow.el --- Narrow-to-region with more eye-candy -*- lexical-binding: t; -*-

;; Copyright (C) 2026 takeokunn <bararararatty@gmail.com>

;; Author: takeokunn <bararararatty@gmail.com>
;; Maintainer: takeokunn <bararararatty@gmail.com>
;; URL: https://github.com/takeokunn/soft-narrow
;; Version: 1.0.0
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
;; Version 1.0.0 requires Emacs 29.1+ and uses modern APIs:
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
(with-no-warnings
  (defvar org-element-greater-elements))

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
  "Cached result of `soft-narrow--compute-intersection'.
A cons (START . END) when valid, nil otherwise.
Recomputed by `soft-narrow--apply-properties' on narrow/widen and by
`soft-narrow--refresh-intersection' from `after-change-functions' after
edits inside the visible region (markers shift, so the cached integer
bounds must be refreshed to keep `soft-narrow--guard-boundary' and
`soft-narrow--clamp-point' accurate).")

(defvar-local soft-narrow--property-snapshot nil
  "Saved original text property state for restoration on final widen.
Captured once on the first `soft-narrow-to-region' call, restored when
all narrowing levels are popped.  Nil or `empty' when no properties
were set at capture time.")

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
Return nil when the buffer is not soft-narrowed or when the narrowing
stack has an empty (non-overlapping) intersection.  Intended for use
with `soft-narrow-with-restriction' to scope buffer-wide operations to
the soft-narrowed region."
  (soft-narrow--compute-intersection))

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

(defun soft-narrow--ensure-overlays ()
  "Ensure persistent overlays exist for this buffer, creating them if needed."
  (unless (overlayp soft-narrow--before-overlay)
    (setq soft-narrow--before-overlay (make-overlay 1 1))
    (overlay-put soft-narrow--before-overlay 'face 'soft-narrow-blocked-face)
    (overlay-put soft-narrow--before-overlay 'soft-narrow t))
  (unless (overlayp soft-narrow--after-overlay)
    (setq soft-narrow--after-overlay (make-overlay 1 1 nil nil t))
    (overlay-put soft-narrow--after-overlay 'face 'soft-narrow-blocked-face)
    (overlay-put soft-narrow--after-overlay 'soft-narrow t)))

(defun soft-narrow--show-overlays (start end)
  "Position persistent overlays to cover blocked regions outside START..END."
  (soft-narrow--ensure-overlays)
  (if (> start (point-min))
      (move-overlay soft-narrow--before-overlay (point-min) start)
    (move-overlay soft-narrow--before-overlay 1 1))
  (if (< end (point-max))
      (move-overlay soft-narrow--after-overlay end (point-max))
    (move-overlay soft-narrow--after-overlay 1 1)))

(defun soft-narrow--hide-overlays ()
  "Collapse persistent overlays to an empty range (effectively hide them)."
  (when (overlayp soft-narrow--before-overlay)
    (move-overlay soft-narrow--before-overlay 1 1))
  (when (overlayp soft-narrow--after-overlay)
    (move-overlay soft-narrow--after-overlay 1 1)))

(defun soft-narrow--destroy-overlays ()
  "Delete persistent overlays and clear buffer-local references."
  (when (overlayp soft-narrow--before-overlay)
    (delete-overlay soft-narrow--before-overlay)
    (setq soft-narrow--before-overlay nil))
  (when (overlayp soft-narrow--after-overlay)
    (delete-overlay soft-narrow--after-overlay)
    (setq soft-narrow--after-overlay nil)))

(defun soft-narrow--capture-property-state ()
  "Capture original text property state for later restoration.
Records positions (as markers that track buffer edits) where `read-only',
`cursor-intangible', `front-sticky', or `rear-nonsticky' have non-nil
values (any non-nil, not just t).  Uses `text-property-not-all' as a
fast-path for the common case where no such properties exist."
  (unless soft-narrow--property-snapshot
    (let ((props '(read-only cursor-intangible front-sticky rear-nonsticky)))
      (if (or (text-property-not-all (point-min) (point-max) 'read-only nil)
              (text-property-not-all (point-min) (point-max) 'cursor-intangible nil)
              (text-property-not-all (point-min) (point-max) 'front-sticky nil)
              (text-property-not-all (point-min) (point-max) 'rear-nonsticky nil))
          ;; Properties found — build snapshot with markers so positions
          ;; track buffer edits (e.g., insertion in visible region).
          (let ((state nil)
                (max (point-max))
                (pos (point-min)))
            (while (< pos max)
              (let ((vals nil))
                (dolist (p props)
                  (let ((v (get-text-property pos p)))
                    (when v (push (cons p v) vals))))
                (when vals
                  (push (cons (copy-marker pos t) (nreverse vals)) state)))
              (setq pos (1+ pos)))
            (setq soft-narrow--property-snapshot (or (nreverse state)
                                                     'empty)))
        ;; Nothing to save — common case
        (setq soft-narrow--property-snapshot 'empty)))))

(defun soft-narrow--restore-property-state ()
  "Restore text properties from snapshot, free markers, then clear snapshot."
  (when soft-narrow--property-snapshot
    (unless (eq soft-narrow--property-snapshot 'empty)
      (with-silent-modifications
        (dolist (entry soft-narrow--property-snapshot)
          (let ((marker (car entry))
                (mpos (marker-position (car entry))))
            (when mpos
              (dolist (pv (cdr entry))
                (put-text-property mpos (1+ mpos) (car pv) (cdr pv))))
            (set-marker marker nil)))))
    (setq soft-narrow--property-snapshot nil)))

(defun soft-narrow--restore-visible-properties (l r)
  "Restore original properties to the visible region [L, R).
Called after `remove-list-of-text-properties' on the entire buffer,
so that other packages' text properties in the visible region are
preserved during the narrow rather than being stripped.
Uses marker positions so buffer edits before this call are tracked."
  (when (and soft-narrow--property-snapshot
             (not (eq soft-narrow--property-snapshot 'empty)))
    (with-silent-modifications
      (dolist (entry soft-narrow--property-snapshot)
        (let* ((marker (car entry))
               (mpos (marker-position marker)))
          (when (and mpos (>= mpos l) (< mpos r))
            (dolist (pv (cdr entry))
             (put-text-property mpos (1+ mpos) (car pv) (cdr pv)))))))))

(defun soft-narrow--apply-properties ()
  "Apply narrowing properties based on current intersection.
Blocked regions get overlay face for visual deemphasis, plus
text properties for cursor restriction and read-only protection.
Also manages buffer-local hooks: a `pre-command-hook' to suppress
boundary-crossing movements and a `post-command-hook' for clamping.
Saves original property state before first narrow and restores it
on final widen to avoid destroying properties set by other packages."
  (let ((intersection (soft-narrow--compute-intersection)))
    (setq soft-narrow--cached-intersection intersection)
    (if-let* ((l (car intersection))
              (r (cdr intersection)))
        (progn
          ;; Capture original property state before first modification
          (soft-narrow--capture-property-state)
          ;; Enable cursor-intangible-mode if not already active;
          ;; track ownership so we only disable it on final widen
          ;; if SOFT-NARROW was the one that enabled it.
          ;; External toggles are detected in real-time via
          ;; `cursor-intangible-mode-hook' (see
          ;; `soft-narrow--on-cursor-intangible-mode-change').
          (unless (bound-and-true-p cursor-intangible-mode)
            (let ((soft-narrow--toggling-cursor-intangible t))
              (setq soft-narrow--owns-cursor-intangible t)
              (cursor-intangible-mode 1)))
          ;; Install hook so external mode toggles release ownership
          (add-hook 'cursor-intangible-mode-hook
                    #'soft-narrow--on-cursor-intangible-mode-change nil t)
          ;; Apply properties to blocked regions.
          ;; We use remove-list-of-text-properties on the entire buffer
          ;; followed by add-text-properties on blocked regions because
          ;; successive narrows may change which regions are blocked vs.
          ;; visible.  After applying, we restore original property
          ;; values to the visible region so other packages' text
          ;; properties are preserved during the narrow.
          (with-silent-modifications
            (remove-list-of-text-properties
             (point-min) (point-max)
             '(cursor-intangible read-only front-sticky rear-nonsticky))
            (add-text-properties (point-min) l
                                 '(cursor-intangible t read-only t
                                   rear-nonsticky (cursor-intangible)
                                   front-sticky (cursor-intangible)))
            (add-text-properties r (point-max)
                                 '(cursor-intangible t read-only t))
            ;; Restore original properties to the visible region [l, r)
            ;; so that other packages' text properties survive the narrow.
            (soft-narrow--restore-visible-properties l r))
          (soft-narrow--show-overlays l r)
          (add-hook 'pre-command-hook #'soft-narrow--guard-boundary nil t)
          ;; Depth 10 ensures this runs after cursor-intangible-mode (depth 0).
          (add-hook 'post-command-hook #'soft-narrow--clamp-point 10 t)
          ;; Refresh cached bounds after edits inside the visible region,
          ;; whose stack markers shift while the cache holds stale integers.
          (add-hook 'after-change-functions
                    #'soft-narrow--refresh-intersection nil t))
      ;; No valid intersection — final widen: restore original state
      (soft-narrow--hide-overlays)
      (with-silent-modifications
        (remove-list-of-text-properties
         (point-min) (point-max)
         '(cursor-intangible read-only front-sticky rear-nonsticky))
        ;; Restore any original property values that were captured
        ;; before the first soft-narrow.
        (soft-narrow--restore-property-state)
        ;; Only disable cursor-intangible-mode if soft-narrow
        ;; was the one that enabled it AND the mode is still on
        ;; (ownership may have been released by external toggle).
        (when (and soft-narrow--owns-cursor-intangible
                   (bound-and-true-p cursor-intangible-mode))
          (let ((soft-narrow--toggling-cursor-intangible t))
            (setq soft-narrow--owns-cursor-intangible nil)
            (cursor-intangible-mode -1))))
      ;; Remove hook in case ownership was released before widen
      (remove-hook 'cursor-intangible-mode-hook
                   #'soft-narrow--on-cursor-intangible-mode-change t)
      (remove-hook 'pre-command-hook #'soft-narrow--guard-boundary t)
      (remove-hook 'post-command-hook #'soft-narrow--clamp-point t)
      (remove-hook 'after-change-functions
                   #'soft-narrow--refresh-intersection t))))

(defun soft-narrow--guard-boundary ()
  "Suppress movement commands that would leave the narrowed region.
Runs in `pre-command-hook' so the cursor never enters blocked areas,
preventing visual flicker from the two-phase post-command correction."
  (when-let* ((intersection soft-narrow--cached-intersection)
              (l (car intersection))
              (r (cdr intersection)))
    (cond
     ;; Bottom boundary: suppress downward/forward movement
     ((and (>= (point) (1- r))
           (memq this-command
                 '(next-line forward-char forward-paragraph
                   scroll-up-command end-of-buffer)))
      (setq this-command #'ignore))
     ;; Top boundary: suppress upward/backward movement
     ((and (<= (point) l)
           (memq this-command
                 '(previous-line backward-char backward-paragraph
                   scroll-down-command beginning-of-buffer)))
      (setq this-command #'ignore)))))

(defun soft-narrow--clamp-point ()
  "Clamp point to the narrowed region boundaries.
Prevents the cursor from resting inside the visually blocked overlay areas.
Added to `post-command-hook' as a buffer-local hook."
  (when-let* ((intersection soft-narrow--cached-intersection)
              (l (car intersection))
              (r (cdr intersection)))
    (cond
     ((< (point) l) (goto-char l))
     ((>= (point) r) (goto-char (max l (1- r)))))))

(defun soft-narrow--refresh-intersection (&rest _)
  "Recompute `soft-narrow--cached-intersection' from the current markers.
Added to `after-change-functions' while narrowing is active.  Editing
inside the visible region shifts the stack markers, so the cached integer
bounds go stale; refreshing here keeps `soft-narrow--guard-boundary' and
`soft-narrow--clamp-point' from clamping the cursor to outdated
boundaries.  Runs only on genuine buffer changes, so per-keystroke motion
still reads the cache in O(1)."
  (setq soft-narrow--cached-intersection (soft-narrow--compute-intersection)))

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
    ;; Move point into the visible region if it landed in a blocked area,
    ;; matching `narrow-to-region' (which always leaves point in bounds).
    ;; Interactive calls also get this via `post-command-hook', but Lisp
    ;; callers rely on this explicit clamp.
    (soft-narrow--clamp-point)
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
  :package-version '(soft-narrow . "1.0.0"))

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
          (soft-narrow-widen))
        (soft-narrow--destroy-overlays)))))

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
