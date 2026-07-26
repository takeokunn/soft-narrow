;;; soft-narrow-test.el --- ERT tests for soft-narrow.el -*- lexical-binding: t; -*-

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

;; Comprehensive test suite for soft-narrow.el covering:
;; - Basic functionality tests
;; - Stackable intersection tests
;; - Cursor restriction tests using cursor-intangible
;; - Read-only tests
;; - Edge cases
;; - Performance tests

;;; Code:

(require 'ert)
(require 'soft-narrow)

(require 'cursor-sensor)
(require 'soft-narrow-test-helpers)

(declare-function org-export-as "ox" (backend &optional subtreep visible-only body-only ext-plist))


;; Basic Functionality Tests

(ert-deftest soft-narrow-basic-narrow-widen ()
  "Test basic narrow and widen cycle."
  (soft-narrow-test--with-buffer 100 buf
    ;; Initially not narrowed
    (should-not (soft-narrow-active-p))

    ;; Narrow to region
    (soft-narrow-to-region 200 400)
    (should (soft-narrow-active-p))

    ;; Widen
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))))

(ert-deftest soft-narrow-active-p-detection ()
  "Test soft-narrow-active-p detection."
  (soft-narrow-test--with-buffer 50 buf
    ;; Not active initially
    (should-not (soft-narrow-active-p))

    ;; Active after narrowing
    (soft-narrow-to-region 100 300)
    (should (soft-narrow-active-p))

    ;; Not active after widening
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))))

(ert-deftest soft-narrow-text-properties ()
  "Test that text properties are correctly applied."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Check overlay face before region
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))

    ;; Check overlay face after region
    (should (soft-narrow-test--has-overlay-face-at 500 'soft-narrow-blocked-face))

    ;; Check no overlay inside region
    (should-not (soft-narrow-test--has-overlay-face-at 300 'soft-narrow-blocked-face))

    ;; Check read-only property before region
    (should (get-char-property 50 'read-only))

    ;; Check read-only property after region
    (should (get-char-property 500 'read-only))

    ;; Check no read-only inside region
    (should-not (get-char-property 300 'read-only))

    ;; Check cursor-intangible property before region
    (should (get-char-property 50 'cursor-intangible))

    ;; Check cursor-intangible property after region
    (should (get-char-property 500 'cursor-intangible))

    ;; Check no cursor-intangible inside region
    (should-not (get-char-property 300 'cursor-intangible))

    ;; Check face property (now on overlay, not text property)
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-invisibility-spec ()
  "Test that buffer-invisibility-spec is not modified."
  (soft-narrow-test--with-buffer 100 buf
    (let ((original-spec buffer-invisibility-spec))
      (soft-narrow-to-region 200 400)

      ;; Should NOT modify buffer-invisibility-spec
      (should (equal buffer-invisibility-spec original-spec))

      (soft-narrow-widen)

      (should (equal buffer-invisibility-spec original-spec)))))


;; Stackable Intersection Tests

(ert-deftest soft-narrow-intersection ()
  "Test that successive narrowing creates intersection."
  (soft-narrow-test--with-buffer 200 buf
    ;; First narrow: 100-300
    (soft-narrow-to-region 100 300)
    (should (= (length soft-narrow--stack) 1))

    ;; Second narrow: 200-400 (should intersect to 200-300)
    (soft-narrow-to-region 200 400)
    (should (= (length soft-narrow--stack) 2))

    ;; Check intersection is computed correctly
    (let ((intersection (soft-narrow--compute-intersection)))
      (should (= (car intersection) 200))
      (should (= (cdr intersection) 300)))

    ;; Check that only intersection is visible (overlay check)
    (should (soft-narrow-test--has-overlay-face-at 150 'soft-narrow-blocked-face))
    (should-not (soft-narrow-test--has-overlay-face-at 250 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 350 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-lifo-widen ()
  "Test LIFO behavior on widen."
  (soft-narrow-test--with-buffer 200 buf
    ;; First narrow
    (soft-narrow-to-region 100 400)
    (should (= (length soft-narrow--stack) 1))

    ;; Second narrow (intersection)
    (soft-narrow-to-region 200 300)
    (should (= (length soft-narrow--stack) 2))

    ;; Widen should pop the stack
    (soft-narrow-widen)
    (should (= (length soft-narrow--stack) 1))

    ;; Should still be narrowed to first region
    (should (soft-narrow-active-p))

    ;; Check intersection is now 100-400
    (let ((intersection (soft-narrow--compute-intersection)))
      (should (= (car intersection) 100))
      (should (= (cdr intersection) 400)))

    ;; Widen again
    (soft-narrow-widen)
    (should (= (length soft-narrow--stack) 0))
    (should-not (soft-narrow-active-p))))

(ert-deftest soft-narrow-stack-marker-management ()
  "Test that markers in the stack are managed correctly."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 100 200)
    (soft-narrow-to-region 150 250)

    ;; Stack should have 2 elements
    (should (= (length soft-narrow--stack) 2))

    ;; Each element should be a cons of markers
    (let ((top (car soft-narrow--stack)))
      (should (markerp (car top)))
      (should (markerp (cdr top))))
    (let ((second (cadr soft-narrow--stack)))
      (should (markerp (car second)))
      (should (markerp (cdr second))))

    ;; Markers should point to correct positions
    (should (= (marker-position (caar soft-narrow--stack)) 150))
    (should (= (marker-position (cdar soft-narrow--stack)) 250))))

(ert-deftest soft-narrow-empty-stack-after-widens ()
  "Test that stack is empty after widening all levels."
  (soft-narrow-test--with-buffer 100 buf
    ;; Add three levels
    (soft-narrow-to-region 50 400)
    (soft-narrow-to-region 100 350)
    (soft-narrow-to-region 150 300)
    (should (= (length soft-narrow--stack) 3))

    ;; Widen all levels
    (soft-narrow-widen)
    (soft-narrow-widen)
    (soft-narrow-widen)

    ;; Stack should be empty
    (should-not soft-narrow--stack)
    (should-not (soft-narrow-active-p))))


;; Cursor Restriction Tests

(ert-deftest soft-narrow-cursor-intangible-before ()
  "Test that cursor-intangible property is set before narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Check that cursor-intangible property is set
    (should (get-char-property 100 'cursor-intangible))
    (should (get-char-property 150 'cursor-intangible))
    ;; Should be set up to the narrow region
    (should (get-char-property 199 'cursor-intangible))
    ;; Should not be set inside the narrow region
    (should-not (get-char-property 200 'cursor-intangible))))

(ert-deftest soft-narrow-cursor-intangible-after ()
  "Test that cursor-intangible property is set after narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Check that cursor-intangible property is set
    (should (get-char-property 500 'cursor-intangible))
    (should (get-char-property 450 'cursor-intangible))
    ;; Should be set from the end of narrow region
    (should (get-char-property 400 'cursor-intangible))
    ;; Should not be set inside the narrow region
    (should-not (get-char-property 399 'cursor-intangible))))

(ert-deftest soft-narrow-cursor-free-inside ()
  "Test that cursor can move freely inside narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Should be able to move anywhere inside
    (goto-char 250)
    (should (= (point) 250))

    (goto-char 300)
    (should (= (point) 300))

    (goto-char 350)
    (should (= (point) 350))))


;; Read-Only Tests

(ert-deftest soft-narrow-readonly-before-region ()
  "Test that editing is blocked before narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Try to insert before region
    (goto-char 100)
    (let ((inhibit-read-only nil))
      (should-error (insert "test") :type 'text-read-only))

    ;; Try to delete before region
    (goto-char 150)
    (let ((inhibit-read-only nil))
      (should-error (delete-char 1) :type 'text-read-only))))

(ert-deftest soft-narrow-readonly-after-region ()
  "Test that editing is blocked after narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Try to insert after region
    (goto-char 500)
    (let ((inhibit-read-only nil))
      (should-error (insert "test") :type 'text-read-only))

    ;; Try to delete after region
    (goto-char 450)
    (let ((inhibit-read-only nil))
      (should-error (delete-char 1) :type 'text-read-only))))

(ert-deftest soft-narrow-editing-allowed-inside ()
  "Test that editing is allowed inside narrowed region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Should be able to insert inside
    (goto-char 250)
    (insert "test")
    (should (string= (buffer-substring 250 254) "test"))

    ;; Should be able to delete inside
    (goto-char 250)
    (delete-char 4)
    ;; After deleting, the original text should be there
    (should-not (string= (buffer-substring 250 254) "test"))))

(ert-deftest soft-narrow-inhibit-read-only-bypass ()
  "Test that inhibit-read-only allows editing outside."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; With inhibit-read-only, should be able to edit
    (let ((inhibit-read-only t))
      (goto-char 100)
      (insert "bypass")
      (should (string= (buffer-substring 100 106) "bypass")))))


;; Edge Cases

(ert-deftest soft-narrow-invalid-bounds ()
  "Test that out-of-range bounds are clamped to buffer boundaries."
  (soft-narrow-test--with-buffer 10 buf
				 ;; Bounds beyond buffer are clamped to point-min/point-max
				 (soft-narrow-to-region 100 1000)
				 (should (soft-narrow-active-p))
				 ;; End should be clamped to point-max
				 (let ((intersection (soft-narrow--compute-intersection)))
				   (should (= (car intersection) 100))
				   (should (= (cdr intersection) (point-max))))))

(ert-deftest soft-narrow-invisibility-spec-t ()
  "Test that buffer-invisibility-spec t is not disrupted."
  (soft-narrow-test--with-buffer 10 buf
    (setq-local buffer-invisibility-spec t)
    (soft-narrow-to-region 20 60)

    ;; Should not have modified buffer-invisibility-spec
    (should (eq buffer-invisibility-spec t))

    (soft-narrow-widen)))

(ert-deftest soft-narrow-entire-buffer ()
  "Test narrowing entire buffer."
  (soft-narrow-test--with-buffer 100 buf
    (let ((size (1+ (buffer-size))))
      (soft-narrow-to-region 1 size)

      ;; Should be narrowed
      (should (soft-narrow-active-p))

      ;; No overlays should be in the region (entire buffer is narrowed)
      ;; Since start=point-min and end=point-max, no blocked regions exist
      (should-not (soft-narrow-test--has-overlay-face-at 100 'soft-narrow-blocked-face))

      ;; No text should be read-only inside the buffer
      ;; Check a few positions
      (should-not (get-char-property 100 'read-only))
      (should-not (get-char-property 500 'read-only))
      (should-not (get-char-property 1000 'read-only)))))

(ert-deftest soft-narrow-single-point ()
  "Test narrowing to single point."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 200)

    ;; Should be narrowed
    (should (soft-narrow-active-p))

    ;; Everything should have overlay face (entire buffer is blocked)
    (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 300 'soft-narrow-blocked-face))

    ;; Everything should be read-only
    (should (get-char-property 1 'read-only))
    (should (get-char-property 300 'read-only))))

(ert-deftest soft-narrow-reverse-arguments ()
  "Test narrowing with reversed start/end arguments."
  (soft-narrow-test--with-buffer 100 buf
    ;; Call with end before start
    (soft-narrow-to-region 400 200)

    ;; Should normalize to start-end
    (let ((intersection (soft-narrow--compute-intersection)))
      (should (= (car intersection) 200))
      (should (= (cdr intersection) 400)))))

(ert-deftest soft-narrow-multiple-cycles ()
  "Test multiple rapid narrow/widen cycles."
  (soft-narrow-test--with-buffer 100 buf
    ;; Perform multiple cycles
    (dotimes (cycle 10)
      (soft-narrow-to-region (* (+ cycle 1) 10) (* (+ cycle 1) 20))
      (should (soft-narrow-active-p))
      (soft-narrow-widen)
      (should-not (soft-narrow-active-p)))

    ;; Should still work after multiple cycles
    (soft-narrow-to-region 100 200)
    (should (soft-narrow-active-p))
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))))

(ert-deftest soft-narrow-widen-when-not-narrowed ()
  "Test widening when not narrowed."
  (soft-narrow-test--with-buffer 100 buf
    ;; Should not error
    (should-not (soft-narrow-active-p))
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))
    (should-not soft-narrow--stack)))

(ert-deftest soft-narrow-marker-insertion-types ()
  "Test that markers have correct insertion types."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Check initial marker positions
          (should (= (marker-position (caar soft-narrow--stack)) 200))
          (should (= (marker-position (cdar soft-narrow--stack)) 400))

          ;; Insert inside the narrowed region (after start marker)
          (let ((inhibit-read-only t))
            (goto-char 201)
            (insert "X"))

          ;; Start marker should stay (insertion-type nil)
          (should (= (marker-position (caar soft-narrow--stack)) 200))

          ;; After first insertion, end marker should move (insertion-type t)
          ;; because the buffer size increased and marker has insertion-type t
          (should (> (marker-position (cdar soft-narrow--stack)) 400))

          ;; Verify start marker did not move
          (should (= (marker-position (caar soft-narrow--stack)) 200)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-disjoint-intersection-pop-restores-prior-frame ()
  "Test that popping a disjoint frame restores the prior visible interval."
  (soft-narrow-test--with-buffer 200 buf
    (soft-narrow-to-region 100 200)
    (soft-narrow-to-region 300 400)
    (should (equal (soft-narrow-region-bounds) (quote (300 . 300))))
    (soft-narrow-widen)
    (should (equal (soft-narrow-region-bounds) (quote (100 . 200))))
    (should-not (get-char-property 150 (quote read-only)))
    (should (get-char-property 300 (quote read-only)))))


;; Property Cleanup Tests

(ert-deftest soft-narrow-property-cleanup-on-widen ()
  "Test that all properties are cleaned up on final widen."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Verify properties are set
    (should (soft-narrow-test--has-overlay-face-at 100 'soft-narrow-blocked-face))
    (should (get-char-property 100 'read-only))
    (should (get-char-property 100 'cursor-intangible))

    (soft-narrow-widen)

    ;; Verify all properties are removed
    (should-not (soft-narrow-test--has-overlay-face-at 100 'soft-narrow-blocked-face))
    (should-not (get-char-property 100 'read-only))
    (should-not (get-char-property 100 'cursor-intangible))))


;; Performance Tests

(ert-deftest soft-narrow-dense-large-buffer-has-constant-overlay-state ()
  "Test 100k densely propertized characters use two overlays and no snapshot."
  (let ((buf (generate-new-buffer " *soft-narrow-dense-large*")))
    (unwind-protect
        (with-current-buffer buf
          (insert (make-string 100000 ?x))
          (dotimes (index 100000)
            (put-text-property (1+ index) (+ index 2)
                               (quote external-dense) (% index 2)))
          (soft-narrow-to-region 25000 75000)
          (should (= (length soft-narrow--stack) 1))
          (should (= (seq-count
                      (lambda (overlay) (overlay-get overlay (quote soft-narrow)))
                      (overlays-in (point-min) (point-max)))
                     2))
          (should-not (boundp (quote soft-narrow--property-snapshot)))
          (should (= (get-text-property 1000 (quote external-dense)) 1))
          (soft-narrow-widen)
          (should (= (get-text-property 1000 (quote external-dense)) 1)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-final-widen-cleanup-is-exception-safe ()
  "Test final widen releases overlays and hooks even when mode cleanup signals."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (cl-letf (((symbol-function (quote soft-narrow--set-cursor-intangible-ownership))
               (lambda (_enable) (error "cleanup failure"))))
      (should-error (soft-narrow-widen) :type (quote error)))
    (should-not soft-narrow--stack)
    (should-not soft-narrow--before-overlay)
    (should-not soft-narrow--after-overlay)
    (should-not soft-narrow--owns-cursor-intangible)
    (should-not (memq (function soft-narrow--guard-boundary) pre-command-hook))
    (should-not (memq (function soft-narrow--clamp-point) post-command-hook))
    (should-not (memq (function soft-narrow--refresh-intersection)
                      after-change-functions))))

(ert-deftest soft-narrow-performance-intersection-computation ()
  "Test performance of intersection computation with deep stack."
  (soft-narrow-test--with-buffer 1000 buf
    ;; Create a deep stack
    (dotimes (i 50)
      (soft-narrow-to-region (* (1+ i) 10) (1+ (* (1+ i) 20))))

    (let ((start (float-time)))
      ;; Compute intersection
      (soft-narrow--compute-intersection)
      ;; Should be fast even with deep stack
      (let ((elapsed (- (float-time) start)))
        (should (< elapsed 0.01))))))


;; Stack Management Tests

(ert-deftest soft-narrow-stack-state-preservation ()
  "Test that stack state is preserved across operations."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 100 500)
    (soft-narrow-to-region 200 400)
    (soft-narrow-to-region 250 350)

    ;; Stack should have 3 elements
    (should (= (length soft-narrow--stack) 3))

    ;; Intersection should be 250-350
    (let ((intersection (soft-narrow--compute-intersection)))
      (should (= (car intersection) 250))
      (should (= (cdr intersection) 350)))

    ;; Partial widen
    (soft-narrow-widen)

    ;; Stack should have 2 elements
    (should (= (length soft-narrow--stack) 2))

    ;; Intersection should now be 200-400
    (let ((intersection (soft-narrow--compute-intersection)))
      (should (= (car intersection) 200))
      (should (= (cdr intersection) 400)))))


;; Buffer-Local Variable Tests

(ert-deftest soft-narrow-buffer-local-stack ()
  "Test that stack is buffer-local."
  (let ((buf1 (soft-narrow-test--create-test-buffer 50))
        (buf2 (soft-narrow-test--create-test-buffer 50)))
    (unwind-protect
        (progn
          (with-current-buffer buf1
            (soft-narrow-to-region 100 200)
            (should (= (length soft-narrow--stack) 1)))

          (with-current-buffer buf2
            (soft-narrow-to-region 50 150)
            (soft-narrow-to-region 75 125)
            (should (= (length soft-narrow--stack) 2))

            ;; buf1 stack should still have 1 element
            (with-current-buffer buf1
              (should (= (length soft-narrow--stack) 1)))))
      (soft-narrow-test--cleanup-buffer buf1)
      (soft-narrow-test--cleanup-buffer buf2))))


;; Org Mode Integration Tests
;; These tests are wrapped to gracefully handle missing org-mode

(ert-deftest soft-narrow-org-to-block ()
  "Test soft-narrow-org-to-block narrows to org block."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "Some text before block\n")
            (insert "#+BEGIN_SRC emacs-lisp\n")
            (insert "(message \"hello\")\n")
            (insert "#+END_SRC\n")
            (insert "Some text after block\n")

            ;; Move inside the block
            (goto-char 40)

            ;; Narrow to block
            (soft-narrow-org-to-block)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; Text before block should have overlay face
            (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face))

            ;; Text after block should have overlay face
            (should (soft-narrow-test--has-overlay-face-at (1- (point-max)) 'soft-narrow-blocked-face))

            ;; Text inside block should not have overlay face
            (should-not (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-block-error-outside ()
  "Test soft-narrow-org-to-block errors when outside block."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "Just some text outside any block\n")

            ;; Should error when not in a block
            (should-error (soft-narrow-org-to-block) :type 'user-error))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-element-headline ()
  "Test soft-narrow-org-to-element narrows to headline."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "* Headline 1\n")
            (insert "Some content\n")
            (insert "** Headline 2\n")
            (insert "More content\n")
            (insert "* Headline 3\n")

            ;; Move to first headline
            (goto-char 1)

            ;; Narrow to element (headline)
            (soft-narrow-org-to-element)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; Should have narrowed the headline
            (let ((intersection (soft-narrow--compute-intersection)))
              (should intersection)
              ;; Should start at position 1
              (should (= (car intersection) 1))))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-element-paragraph ()
  "Test soft-narrow-org-to-element narrows to paragraph."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "First paragraph\n")
            (insert "\n")
            (insert "Second paragraph\n")
            (insert "\n")
            (insert "Third paragraph\n")

            ;; Move to second paragraph
            (goto-char 25)

            ;; Narrow to element
            (soft-narrow-org-to-element)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; First paragraph should have overlay face
            (goto-char 1)
            (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-element-greater-element ()
  "Test soft-narrow-org-to-element narrows to greater element contents."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "#+BEGIN_QUOTE\n")
            (insert "Quote content here\n")
            (insert "More quote content\n")
            (insert "#+END_QUOTE\n")

            ;; Move inside the quote block
            (goto-char 25)

            ;; Narrow to element
            (soft-narrow-org-to-element)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; Should narrow to contents, not including markers
            (goto-char 1)
            (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-subtree ()
  "Test soft-narrow-org-to-subtree narrows to subtree."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "* Top level 1\n")
            (insert "Content 1\n")
            (insert "** Sub level 1\n")
            (insert "Sub content 1\n")
            (insert "** Sub level 2\n")
            (insert "Sub content 2\n")
            (insert "* Top level 2\n")
            (insert "Content 2\n")

            ;; Move to "Top level 1"
            (goto-char 1)

            ;; Narrow to subtree
            (soft-narrow-org-to-subtree)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; Should include "Top level 1" and its children
            ;; but not "Top level 2"
            (let ((intersection (soft-narrow--compute-intersection)))
              (should intersection)
              ;; Should start at position 1
              (should (= (car intersection) 1))
              ;; Should end before "Top level 2"
              (should (< (cdr intersection) (point-max)))))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-subtree-nested ()
  "Test soft-narrow-org-to-subtree with nested subtrees."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "* Top level\n")
            (insert "** Sub level 1\n")
            (insert "Content 1\n")
            (insert "*** Sub sub level\n")
            (insert "Deep content\n")
            (insert "** Sub level 2\n")
            (insert "Content 2\n")

            ;; Move to "Sub level 1"
            (goto-char 20)

            ;; Narrow to subtree
            (soft-narrow-org-to-subtree)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; Should include "Sub level 1" and its children
            ;; but not "Sub level 2"
            (let ((intersection (soft-narrow--compute-intersection)))
              (should intersection)
              ;; Should end before "Sub level 2"
              (should (< (cdr intersection) (point-max)))))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))

(ert-deftest soft-narrow-org-to-subtree-error-before-heading ()
  "Test soft-narrow-org-to-subtree handles position before first heading."
  :tags '(org-mode)
  (when (require 'org nil t)
    (let ((buf (generate-new-buffer " *soft-narrow-org-test*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (erase-buffer)
            (insert "Text before heading\n")
            (insert "* First heading\n")

            ;; Move before first heading
            (goto-char 1)

            ;; Should handle gracefully - either narrow or error
            (condition-case nil
                (progn
                  (soft-narrow-org-to-subtree)
                  ;; If it succeeds, should be narrowed
                  (should (soft-narrow-active-p)))
              (error
               ;; If it errors, that's also acceptable behavior
               t)))
        (when (buffer-live-p buf)
          (kill-buffer buf))))))


;; Defun and Page Narrowing Tests

(ert-deftest soft-narrow-to-defun-basic ()
  "Test soft-narrow-to-defun narrows to current defun."
  (let ((buf (generate-new-buffer " *soft-narrow-defun-test*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (erase-buffer)
          (insert "(defun test-function-1 ()\n")
          (insert "  \"Docstring.\"\n")
          (insert "  (message \"test\"))\n")
          (insert "\n")
          (insert "(defun test-function-2 ()\n")
          (insert "  \"Another docstring.\"\n")
          (insert "  (message \"test2\"))\n")

          ;; Move inside first defun
          (goto-char 30)

          ;; Narrow to defun
          (soft-narrow-to-defun)

          ;; Should be narrowed
          (should (soft-narrow-active-p))

          ;; Second function should have overlay face
          (goto-char (point-max))
          (forward-line -2)
          (should (soft-narrow-test--has-overlay-face-at (point) 'soft-narrow-blocked-face)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-to-defun-end-of-buffer ()
  "Test soft-narrow-to-defun at end of buffer."
  (let ((buf (generate-new-buffer " *soft-narrow-defun-test*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (erase-buffer)
          (insert "(defun test-function ()\n")
          (insert "  \"Docstring.\"\n")
          (insert "  (message \"test\"))\n")

          ;; Move to end
          (goto-char (point-max))

          ;; Narrow to defun
          (soft-narrow-to-defun)

          ;; Should be narrowed
          (should (soft-narrow-active-p)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-to-page-basic ()
  "Test soft-narrow-to-page narrows to current page."
  (let ((buf (generate-new-buffer " *soft-narrow-page-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "Page 1 content\n")
          (insert "More page 1\n")
          (insert "\f\n")
          (insert "Page 2 content\n")
          (insert "More page 2\n")
          (insert "\f\n")
          (insert "Page 3 content\n")

          ;; Move to page 2
          (goto-char 30)

          ;; Narrow to page
          (soft-narrow-to-page)

          ;; Should be narrowed
          (should (soft-narrow-active-p))

          ;; Page 1 should have overlay face
          (goto-char 1)
          (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-to-page-with-argument ()
  "Test soft-narrow-to-page with positive argument."
  (let ((buf (generate-new-buffer " *soft-narrow-page-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "Page 1\n\f\n")
          (insert "Page 2\n\f\n")
          (insert "Page 3\n")

          ;; Start at beginning
          (goto-char 1)

          ;; Narrow to next page (arg = 1)
          (soft-narrow-to-page 1)

          ;; Should be narrowed to page 2
          (should (soft-narrow-active-p))

          ;; Page 1 should have overlay face
          (goto-char 1)
          (should (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


;; Minor Mode Tests

(ert-deftest soft-narrow-mode-activation ()
  "Test soft-narrow-mode can be activated."
  (let ((buf (generate-new-buffer " *soft-narrow-mode-test*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Ensure mode is off
          (soft-narrow-mode 0)
          (should-not soft-narrow-mode)

          ;; Activate mode
          (soft-narrow-mode 1)

          ;; Should be active
          (should soft-narrow-mode)

          ;; Deactivate mode
          (soft-narrow-mode 0)

          ;; Should be inactive
          (should-not soft-narrow-mode))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-mode-keybinding-widen ()
  "Test soft-narrow-mode binds C-x nw to soft-narrow-widen."
  (let ((buf (generate-new-buffer " *soft-narrow-mode-test*")))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-mode 1)

          ;; Check that C-x nw is bound
          (should (key-binding [?\C-x ?n ?w]))

          ;; Check it's bound to the right function
          (let ((binding (key-binding [?\C-x ?n ?w])))
            (should (eq binding 'soft-narrow-widen)))

          (soft-narrow-mode 0))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-mode-keybindings-all ()
  "Test all soft-narrow-mode keybindings are correct."
  (let ((buf (generate-new-buffer " *soft-narrow-mode-test*")))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-mode 1)

          ;; Check all keybindings
          (should (eq (key-binding [?\C-x ?n ?n]) 'soft-narrow-to-region))
          (should (eq (key-binding [?\C-x ?n ?w]) 'soft-narrow-widen))
          (should (eq (key-binding [?\C-x ?n ?d]) 'soft-narrow-to-defun))
          (should (eq (key-binding [?\C-x ?n ?p]) 'soft-narrow-to-page))
          (should (eq (key-binding [?\C-x ?n ?b]) 'soft-narrow-org-to-block))
          (should (eq (key-binding [?\C-x ?n ?e]) 'soft-narrow-org-to-element))
          (should (eq (key-binding [?\C-x ?n ?s]) 'soft-narrow-org-to-subtree))

          (soft-narrow-mode 0))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-mode-auto-enable ()
  "Test that soft-narrow-to-region auto-enables soft-narrow-mode."
  (soft-narrow-test--with-buffer 50 buf
    ;; Ensure mode is off
    (soft-narrow-mode 0)
    (should-not soft-narrow-mode)

    ;; Narrow without mode
    (soft-narrow-to-region 100 300)

    ;; Mode should be auto-enabled
    (should soft-narrow-mode)

    ;; And narrowing should work
    (should (soft-narrow-active-p))

    ;; C-x n w should be bound to soft-narrow-widen
    (should (eq (key-binding [?\C-x ?n ?w]) 'soft-narrow-widen))

    ;; Clean up
    (soft-narrow-widen)
    (soft-narrow-mode 0)))


;; Inverted Intersection Fix Tests

(ert-deftest soft-narrow-disjoint-intersection-has-zero-width-bounds ()
  "Test that disjoint frames normalize to active zero-width bounds."
  (soft-narrow-test--with-buffer 200 buf
    (soft-narrow-to-region 100 200)
    (soft-narrow-to-region 300 400)
    (should (equal (soft-narrow--compute-intersection) (quote (300 . 300))))
    (should (get-char-property 150 (quote cursor-intangible)))
    (should (get-char-property 350 (quote cursor-intangible)))))

(ert-deftest soft-narrow-touching-intersection-blocks-entire-buffer ()
  "Test that touching frames produce active zero-width bounds."
  (soft-narrow-test--with-buffer 200 buf
    (soft-narrow-to-region 100 200)
    (soft-narrow-to-region 200 400)
    (should (equal (soft-narrow--compute-intersection) (quote (200 . 200))))
    (should (get-char-property 150 (quote read-only)))
    (should (get-char-property 300 (quote read-only)))
    (soft-narrow-widen)
    (should-not (get-char-property 150 (quote read-only)))
    (should (get-char-property 300 (quote read-only)))))


;; Boundary Conditions Tests

(ert-deftest soft-narrow-boundary-buffer-start ()
  "Test narrowing to region starting at buffer start."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 1 300)

    (should (soft-narrow-active-p))

    ;; Nothing should have overlay face before the region
    ;; because we start at point-min
    (goto-char 1)
    (should-not (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face))

    ;; Text after region should have overlay face
    (goto-char 500)
    (should (soft-narrow-test--has-overlay-face-at 500 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-boundary-buffer-end ()
  "Test narrowing to region ending at buffer end."
  (soft-narrow-test--with-buffer 100 buf
    (let ((size (1+ (buffer-size))))
      (soft-narrow-to-region 200 size)

      (should (soft-narrow-active-p))

      ;; Text before region should have overlay face
      (goto-char 100)
      (should (soft-narrow-test--has-overlay-face-at 100 'soft-narrow-blocked-face))

      ;; Nothing should have overlay face after region
      ;; because we end at point-max
      (goto-char size)
      (should-not (soft-narrow-test--has-overlay-face-at size 'soft-narrow-blocked-face)))))

(ert-deftest soft-narrow-boundary-zero-length ()
  "Test narrowing with zero-length region at various positions."
  (soft-narrow-test--with-buffer 100 buf
    ;; Zero-length at middle
    (soft-narrow-to-region 250 250)

    (should (soft-narrow-active-p))

    ;; Everything should have overlay face for a zero-length region
    (should (soft-narrow-test--has-overlay-face-at 100 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 400 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 250 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-boundary-very-small-region ()
  "Test narrowing to a very small region (1 character)."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 250 251)

    (should (soft-narrow-active-p))

    ;; Position 250 should not have overlay face (inside region)
    (should-not (soft-narrow-test--has-overlay-face-at 250 'soft-narrow-blocked-face))

    ;; Position 251 and beyond should have overlay face
    (should (soft-narrow-test--has-overlay-face-at 251 'soft-narrow-blocked-face))

    ;; Position 249 and before should have overlay face
    (should (soft-narrow-test--has-overlay-face-at 249 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-boundary-point-min-max ()
  "Test narrowing using point-min and point-max directly."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region (point-min) (point-max))

    (should (soft-narrow-active-p))

    ;; No overlay face should be present (entire buffer narrowed)
    (should-not (soft-narrow-test--has-overlay-face-at 1 'soft-narrow-blocked-face))
    (should-not (soft-narrow-test--has-overlay-face-at 500 'soft-narrow-blocked-face))
    (should-not (soft-narrow-test--has-overlay-face-at (point-max) 'soft-narrow-blocked-face))))


;; Boundary Clamping Tests

(ert-deftest soft-narrow-boundary-clamp-bottom ()
  "Test that cursor at r is clamped to r-1."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    (should (soft-narrow-active-p))

    ;; Move to exactly r (position 400, which is blocked)
    (goto-char 400)
    (soft-narrow--clamp-point)

    ;; Cursor should be clamped to r-1 = 399
    (should (= (point) 399))))

(ert-deftest soft-narrow-boundary-clamp-past-bottom ()
  "Test that cursor past r is clamped to r-1."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    (should (soft-narrow-active-p))

    ;; Move past r into the blocked after-region
    (goto-char 450)
    (soft-narrow--clamp-point)

    ;; Cursor should be clamped to r-1 = 399
    (should (= (point) 399))))

(ert-deftest soft-narrow-boundary-clamp-top ()
  "Test that cursor before l is clamped to l."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    (should (soft-narrow-active-p))

    ;; Move before l into the blocked before-region
    (goto-char 150)
    (soft-narrow--clamp-point)

    ;; Cursor should be clamped to l = 200
    (should (= (point) 200))))

(ert-deftest soft-narrow-boundary-clamp-no-op-inside ()
  "Test that cursor inside the narrow region is not moved."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    (should (soft-narrow-active-p))

    ;; Move to a position inside the narrow region
    (goto-char 300)
    (soft-narrow--clamp-point)

    ;; Cursor should remain at 300 (no clamping needed)
    (should (= (point) 300))))

(ert-deftest soft-narrow-boundary-clamp-inactive ()
  "Test that clamp-point is a no-op when soft-narrow is inactive."
  (soft-narrow-test--with-buffer 100 buf
    ;; Do NOT call soft-narrow-to-region; mode remains inactive
    (should-not (soft-narrow-active-p))

    (goto-char 150)
    (soft-narrow--clamp-point)

    ;; Cursor must not move when soft-narrow is inactive
    (should (= (point) 150))))

(ert-deftest soft-narrow-boundary-clamp-stacked-intersection ()
  "Test clamping uses the intersection of stacked narrows."
  (soft-narrow-test--with-buffer 100 buf
    ;; First narrow: [100, 400)
    (soft-narrow-to-region 100 400)
    ;; Second narrow: [200, 350) — intersection becomes [200, 350)
    (soft-narrow-to-region 200 350)

    (should (soft-narrow-active-p))

    ;; Move to r of the intersection (350 is blocked)
    (goto-char 350)
    (soft-narrow--clamp-point)

    ;; Cursor should be clamped to intersection r-1 = 349
    (should (= (point) 349))))


;; Integration Scenario Tests

(ert-deftest soft-narrow-integration-edit-workflow ()
  "Test realistic editing workflow with multiple narrows."
  (soft-narrow-test--with-buffer 100 buf
    ;; Initial narrow
    (soft-narrow-to-region 200 600)
    (should (soft-narrow-active-p))

    ;; Edit inside region
    (goto-char 300)
    (insert "EDITED")

    ;; Narrow further (stackable)
    (soft-narrow-to-region 250 400)
    (should (= (length soft-narrow--stack) 2))

    ;; Edit in intersection
    (goto-char 300)
    (insert "MORE")

    ;; Widen one level
    (soft-narrow-widen)
    (should (= (length soft-narrow--stack) 1))
    (should (soft-narrow-active-p))

    ;; Edit in broader region
    (goto-char 500)
    (insert "FINAL")

    ;; Widen completely
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))

    ;; Verify all edits persisted
    (should (string-match "EDITED" (buffer-string)))
    (should (string-match "MORE" (buffer-string)))
    (should (string-match "FINAL" (buffer-string)))))


;; Source Code Verification Tests

(ert-deftest soft-narrow-no-defadvice ()
  "Verify that soft-narrow.el does not use defadvice."
  (let ((source-file (expand-file-name "soft-narrow.el"
                                       (file-name-directory
                                        (locate-library "soft-narrow")))))
    (should (file-exists-p source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (goto-char (point-min))
      (should-not (search-forward "defadvice" nil t)))))


(ert-deftest soft-narrow-integration-copy-paste-workflow ()
  "Test copy and paste workflow while narrowed."
  (soft-narrow-test--with-buffer 100 buf
    ;; Narrow to region
    (soft-narrow-to-region 300 500)

    ;; Copy some text
    (goto-char 350)
    (set-mark 380)
    (copy-region-as-kill (region-beginning) (region-end))

    ;; Paste it elsewhere inside region
    (goto-char 450)
    (yank)

    ;; Should still be narrowed
    (should (soft-narrow-active-p))

    ;; Widen
    (soft-narrow-widen)

    ;; Verify paste worked
    (goto-char 450)
    (should (search-forward "Line" 490 t))))

(ert-deftest soft-narrow-integration-search-replace-workflow ()
  "Test search and replace workflow while narrowed."
  (soft-narrow-test--with-buffer 100 buf
    ;; Add specific content to search for
    (goto-char 250)
    (insert "REPLACE_ME")
    (goto-char 350)
    (insert "REPLACE_ME")
    (goto-char 550)
    (insert "REPLACE_ME")

    ;; Narrow to middle region
    (soft-narrow-to-region 200 400)

    ;; Replace within narrowed region
    (goto-char 200)
    (while (search-forward "REPLACE_ME" 400 t)
      (replace-match "REPLACED"))

    ;; Widen
    (soft-narrow-widen)

    ;; Count replacements - should be 2 (one at 250, one at 350)
    (let ((count 0))
      (goto-char 1)
      (while (search-forward "REPLACED" nil t)
        (setq count (1+ count)))
      (should (= count 2)))

    ;; The one outside should still be there
    (goto-char 540)
    (should (search-forward "REPLACE_ME" 570 t))))


;; Security Tests

(ert-deftest soft-narrow-security-marker-cleanup ()
  "Test that markers are properly cleaned up on widen."
  (soft-narrow-test--with-buffer 10 buf
    (soft-narrow-to-region 20 80)
    (soft-narrow-to-region 30 70)
    (soft-narrow-widen)
    (soft-narrow-widen)
    ;; Stack should be empty
    (should-not soft-narrow--stack)))

(ert-deftest soft-narrow-security-buffer-isolation ()
  "Test that narrowing in one buffer does not affect other buffers."
  (let ((buf1 (soft-narrow-test--create-test-buffer 10))
        (buf2 (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (progn
          (with-current-buffer buf2
            (soft-narrow-to-region 20 80)
            ;; Check that buf1 is not affected
            (with-current-buffer buf1
              (should-not (soft-narrow-active-p)))))
      (soft-narrow-test--cleanup-buffer buf1)
      (soft-narrow-test--cleanup-buffer buf2))))

(ert-deftest soft-narrow-security-empty-buffer ()
  "Test that narrowing handles empty buffer gracefully."
  (let ((buf (generate-new-buffer " *soft-narrow-empty-test*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Should handle empty buffer without error
          (condition-case err
              (soft-narrow-to-region 1 1)
            (error (error "Empty buffer handling failed: %S" err))))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-security-single-point-region ()
  "Test that single-point region narrowing works correctly."
  (soft-narrow-test--with-buffer 10 buf
    ;; Should handle single-point region without error
    (soft-narrow-to-region 50 50)
    (should (soft-narrow-active-p))))

(ert-deftest soft-narrow-security-reversed-order-stack ()
  "Test stack integrity with reversed order arguments."
  (soft-narrow-test--with-buffer 10 buf
    (soft-narrow-to-region 80 20)  ; reversed
    (soft-narrow-to-region 40 60)  ; normal
    ;; Stack should have proper markers
    (should (>= (length soft-narrow--stack) 2))))

(ert-deftest soft-narrow-security-no-runtime-eval ()
  "Verify no runtime eval in soft-narrow.el."
  (let ((source-file (expand-file-name "soft-narrow.el"
                                       (file-name-directory
                                        (locate-library "soft-narrow")))))
    (should (file-exists-p source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (goto-char (point-min))
      (should-not (re-search-forward "^(eval " nil t)))))


;; Overlay and Display Mode Tests

(ert-deftest soft-narrow-overlay-creation ()
  "Test that overlays are created in blocked regions."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Should have overlays in blocked regions
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 500 'soft-narrow-blocked-face))

    ;; Should NOT have overlay inside narrowed region
    (should-not (soft-narrow-test--has-overlay-face-at 300 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-overlay-cleanup-on-widen ()
  "Test that overlays are hidden (no face) on final widen."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Overlays are visible
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))

    (soft-narrow-widen)

    ;; Overlays should no longer cover blocked regions
    (should-not (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-overlay-recreation-on-stack ()
  "Test that overlays are recreated on push/pop."
  (soft-narrow-test--with-buffer 200 buf
    ;; First narrow: 100-300
    (soft-narrow-to-region 100 300)
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 350 'soft-narrow-blocked-face))

    ;; Second narrow: 200-400 (intersection: 200-300)
    (soft-narrow-to-region 200 400)
    ;; Before-overlay should cover up to 200 now
    (should (soft-narrow-test--has-overlay-face-at 150 'soft-narrow-blocked-face))
    ;; After-overlay should cover from 300
    (should (soft-narrow-test--has-overlay-face-at 350 'soft-narrow-blocked-face))
    ;; Inside intersection should have no overlay
    (should-not (soft-narrow-test--has-overlay-face-at 250 'soft-narrow-blocked-face))

    ;; Pop one level
    (soft-narrow-widen)
    ;; Now overlays should reflect 100-300 again
    (should (soft-narrow-test--has-overlay-face-at 50 'soft-narrow-blocked-face))
    (should (soft-narrow-test--has-overlay-face-at 350 'soft-narrow-blocked-face))
    (should-not (soft-narrow-test--has-overlay-face-at 200 'soft-narrow-blocked-face))))

(ert-deftest soft-narrow-overlay-tagged ()
  "Test that overlays are tagged with soft-narrow property."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Check overlay has soft-narrow tag
    (let ((ovs (overlays-at 50)))
      (should (seq-some (lambda (ov) (overlay-get ov 'soft-narrow)) ovs)))))


;; Stickiness and Boundary Tests

(ert-deftest soft-narrow-preserves-external-property-added-while-active ()
  "Test that an external text property added while active survives widen."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    (let ((inhibit-read-only t))
      (put-text-property 350 360 (quote external-flag) (quote added)))
    (soft-narrow-widen)
    (should (eq (get-text-property 350 (quote external-flag)) (quote added)))))

(ert-deftest soft-narrow-preserves-external-property-change-while-active ()
  "Test that changing an external text property while active survives widen."
  (soft-narrow-test--with-buffer 50 buf
    (put-text-property 350 360 (quote external-flag) (quote old))
    (soft-narrow-to-region 100 300)
    (let ((inhibit-read-only t))
      (put-text-property 350 360 (quote external-flag) (quote new)))
    (soft-narrow-widen)
    (should (eq (get-text-property 350 (quote external-flag)) (quote new)))))

(ert-deftest soft-narrow-property-bearing-last-char-deletion ()
  "Test deleting a property-bearing last character before final widen."
  (let ((buf (generate-new-buffer " *soft-narrow-delete-last*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "abcdef")
          (put-text-property 6 7 (quote external-flag) (quote last))
          (soft-narrow-to-region 2 5)
          (let ((inhibit-read-only t))
            (delete-region 6 7))
          (soft-narrow-widen)
          (should (equal (buffer-string) "abcde")))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-property-bearing-middle-char-deletion ()
  "Test deleting a property-bearing middle character before final widen."
  (let ((buf (generate-new-buffer " *soft-narrow-delete-middle*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "abcdef")
          (put-text-property 3 4 (quote external-flag) (quote middle))
          (soft-narrow-to-region 2 5)
          (goto-char 3)
          (delete-char 1)
          (soft-narrow-widen)
          (should (equal (buffer-string) "abdef")))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))

(ert-deftest soft-narrow-boundary-intangible-exact ()
  "Test cursor-intangible boundaries are exact at narrowed region edges."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)

    ;; Position 199 (last char before region) should be intangible
    (should (get-char-property 199 'cursor-intangible))
    ;; Position 200 (first char of region) should NOT be intangible
    (should-not (get-char-property 200 'cursor-intangible))
    ;; Position 399 (last char of region) should NOT be intangible
    (should-not (get-char-property 399 'cursor-intangible))
    ;; Position 400 (first char after region) should be intangible
    (should (get-char-property 400 'cursor-intangible))))

(ert-deftest soft-narrow-boundary-get-pos-property ()
  "Test overlay-aware position properties at narrowed boundaries."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (should-not (get-char-property 200 (quote cursor-intangible)))
    (should (get-char-property 400 (quote cursor-intangible)))
    (should (get-pos-property 199 (quote cursor-intangible)))
    (should (get-pos-property 401 (quote cursor-intangible)))))

(ert-deftest soft-narrow-stacked-boundary-get-pos-property ()
  "Test overlay-aware boundary properties across stack transitions."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 100 300)
    (should-not (get-char-property 100 (quote cursor-intangible)))
    (should (get-char-property 300 (quote cursor-intangible)))
    (soft-narrow-to-region 200 400)
    (should-not (get-char-property 200 (quote cursor-intangible)))
    (should (get-char-property 300 (quote cursor-intangible)))
    (should (get-char-property 199 (quote cursor-intangible)))
    (soft-narrow-widen)
    (should-not (get-char-property 100 (quote cursor-intangible)))
    (should (get-char-property 300 (quote cursor-intangible)))))

(ert-deftest soft-narrow-boundary-end-at-point-max ()
  "Test get-pos-property when the narrowed region ends at point-max.
When r == point-max, the after-region is empty and no cursor-intangible
properties should be set beyond the narrowed region end."
  (soft-narrow-test--with-buffer 100 buf
    (let ((size (point-max)))
      (soft-narrow-to-region 200 size)

      ;; Start boundary should not be intangible
      (should-not (get-pos-property 200 'cursor-intangible))
      ;; Before start should be intangible
      (should (get-pos-property 199 'cursor-intangible))
      ;; End boundary (point-max) should not be intangible
      (should-not (get-pos-property size 'cursor-intangible))
      ;; No front-sticky at the end
      (should-not (get-char-property (max (1- size) (point-min)) 'front-sticky)))))


;; Mode Deactivation and Cleanup Tests

(ert-deftest soft-narrow-mode-deactivation-cleans-each-buffer-once ()
  "Test global disable performs one bulk cleanup per active buffer."
  (let ((buf1 (soft-narrow-test--create-test-buffer 50))
        (buf2 (soft-narrow-test--create-test-buffer 50))
        (calls nil)
        (original (symbol-function (quote soft-narrow--cleanup))))
    (unwind-protect
        (progn
          (soft-narrow-mode 1)
          (dolist (buf (list buf1 buf2))
            (with-current-buffer buf
              (soft-narrow-to-region 50 400)
              (soft-narrow-to-region 100 350)
              (soft-narrow-to-region 150 300)
              (should (= (length soft-narrow--stack) 3))
              (should (= (seq-count
                          (lambda (overlay) (overlay-get overlay (quote soft-narrow)))
                          (overlays-in (point-min) (point-max)))
                         2))))
          (cl-letf (((symbol-function (quote soft-narrow--cleanup))
                     (lambda ()
                       (push (current-buffer) calls)
                       (funcall original))))
            (soft-narrow-mode -1))
          (dolist (buf (list buf1 buf2))
            (should (= (seq-count (lambda (called) (eq called buf)) calls) 1))
            (with-current-buffer buf
              (should-not soft-narrow--stack)
              (should (= (seq-count
                          (lambda (overlay) (overlay-get overlay (quote soft-narrow)))
                          (overlays-in (point-min) (point-max)))
                         0)))))
      (soft-narrow-test--cleanup-buffer buf1)
      (soft-narrow-test--cleanup-buffer buf2))))

(ert-deftest soft-narrow-cursor-intangible-mode-disabled-on-final-widen ()
  "Test that `cursor-intangible-mode' is disabled on final widen."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    ;; cursor-intangible-mode should be active
    (should (bound-and-true-p cursor-intangible-mode))
    ;; Final widen
    (soft-narrow-widen)
    ;; cursor-intangible-mode should be disabled
    (should-not (bound-and-true-p cursor-intangible-mode))))

(ert-deftest soft-narrow-markers-nil-after-widen ()
  "Test that markers are freed after widening."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    ;; Capture marker references before widen
    (let ((start-marker (caar soft-narrow--stack))
          (end-marker (cdar soft-narrow--stack)))
      ;; Markers are valid
      (should (marker-position start-marker))
      (should (marker-position end-marker))
      ;; Widen pops and cleans up
      (soft-narrow-widen)
      ;; Markers should now be freed (position nil)
      (should-not (marker-position start-marker))
      (should-not (marker-position end-marker)))))

(ert-deftest soft-narrow-extra-widen-is-harmless ()
  "Test that calling `soft-narrow-widen' an extra time is harmless."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    (should (soft-narrow-active-p))
    ;; First widen: removes the narrowing
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))
    ;; Second widen: no-op, should not error
    (soft-narrow-widen)
    (should-not (soft-narrow-active-p))))

(ert-deftest soft-narrow-to-page-negative-argument ()
  "Test `soft-narrow-to-page' with a negative argument."
  (let ((buf (generate-new-buffer " *soft-narrow-page-test*")))
    (unwind-protect
        (with-current-buffer buf
          (erase-buffer)
          (insert "Page 1\n\f\n")
          (insert "Page 2\n\f\n")
          (insert "Page 3\n")

          ;; Start at end of buffer (page 3)
          (goto-char (point-max))

          ;; Narrow to previous page (arg = -1)
          (soft-narrow-to-page -1)

          ;; Should be narrowed
          (should (soft-narrow-active-p)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))



;; Intersection Edge-Case Tests

(ert-deftest soft-narrow-compute-intersection-empty-stack ()
  "Test that `soft-narrow--compute-intersection' returns nil for empty stack."
  (soft-narrow-test--with-buffer 10 buf
    (should-not soft-narrow--stack)
    (should-not (soft-narrow--compute-intersection))))

(ert-deftest soft-narrow-compute-intersection-single-frame ()
  "Test `soft-narrow--compute-intersection' with exactly one frame.
The dolist loop body never executes; result is returned from the initializer."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 100 300)
    (let ((result (soft-narrow--compute-intersection)))
      (should result)
      (should (= (car result) 100))
      (should (= (cdr result) 300)))))


;; Defun Narrowing Additional Tests

(ert-deftest soft-narrow-to-defun-blank-lines-between-defuns ()
  "Test `soft-narrow-to-defun' when blank lines separate consecutive defuns.
Exercises the `while (looking-at \"^\\n\")' skip-blank-lines loop."
  (let ((buf (generate-new-buffer " *soft-narrow-defun-test*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (erase-buffer)
          (insert "(defun soft-test-fn-1 ()\n")
          (insert "  (message \"1\"))\n")
          (insert "\n")
          (insert "\n")
          (insert "(defun soft-test-fn-2 ()\n")
          (insert "  (message \"2\"))\n")
          ;; Move inside the first defun body
          (goto-char 15)
          (soft-narrow-to-defun)
          (should (soft-narrow-active-p)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest soft-narrow-to-defun-between-defuns ()
  "Test `soft-narrow-to-defun' when point is between two defuns.
Exercises the correction path where `beginning-of-defun' overshoots."
  (let ((buf (generate-new-buffer " *soft-narrow-defun-test*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (erase-buffer)
          (insert "(defun soft-test-fn-a ()\n")
          (insert "  (message \"a\"))\n")
          (insert "\n")
          (insert "(defun soft-test-fn-b ()\n")
          (insert "  (message \"b\"))\n")
          ;; Point on the blank line between the two defuns
          (goto-char (+ (length "(defun soft-test-fn-a ()\n  (message \"a\"))\n") 1))
          ;; Should not error; narrows to one of the surrounding defuns
          (soft-narrow-to-defun)
          (should (soft-narrow-active-p)))
      (when (buffer-live-p buf) (kill-buffer buf)))))


(ert-deftest soft-narrow-destroy-overlays-without-overlays () "Test overlay destruction is idempotent when no overlays exist." (soft-narrow-test--with-buffer 10 buf (should-not soft-narrow--before-overlay) (should-not soft-narrow--after-overlay) (soft-narrow--destroy-overlays) (should-not soft-narrow--before-overlay) (should-not soft-narrow--after-overlay)))


;; Boundary Guard Tests

(ert-deftest soft-narrow-guard-bottom-next-line ()
  "Test that next-line at bottom boundary is suppressed by pre-command guard."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    ;; Move to last position in narrowed region
    (goto-char 199)
    (let ((this-command 'next-line))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-top-previous-line ()
  "Test that previous-line at top boundary is suppressed by pre-command guard."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    ;; Move to first position in narrowed region
    (goto-char 50)
    (let ((this-command 'previous-line))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-allows-interior-movement ()
  "Test that movement commands within the region are not suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    ;; Move to middle of narrowed region
    (goto-char 100)
    ;; next-line should NOT be suppressed
    (let ((this-command 'next-line))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'next-line)))
    ;; previous-line should NOT be suppressed
    (let ((this-command 'previous-line))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'previous-line)))))

(ert-deftest soft-narrow-guard-bottom-forward-char ()
  "Test that forward-char at last position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 199)
    (let ((this-command 'forward-char))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-top-backward-char ()
  "Test that backward-char at first position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 50)
    (let ((this-command 'backward-char))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-hook-cleanup-on-widen ()
  "Test that the pre-command-hook is removed when widening."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    ;; Hook should be installed
    (should (memq #'soft-narrow--guard-boundary
                  (buffer-local-value 'pre-command-hook buf)))
    ;; Widen
    (soft-narrow-widen)
    ;; Hook should be removed
    (should-not (memq #'soft-narrow--guard-boundary
                      (buffer-local-value 'pre-command-hook buf)))))


(ert-deftest soft-narrow-guard-noop-when-inactive ()
  "Test that guard is a no-op when soft-narrow--cached-intersection is nil."
  (soft-narrow-test--with-buffer 20 buf
    ;; No narrowing active — cache is nil
    (should-not soft-narrow--cached-intersection)
    (goto-char 50)
    (let ((this-command 'next-line))
      (soft-narrow--guard-boundary)
      ;; Command must not be suppressed
      (should (eq this-command 'next-line)))))

(ert-deftest soft-narrow-guard-bottom-forward-paragraph ()
  "Test that forward-paragraph at last position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 199)
    (let ((this-command 'forward-paragraph))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-top-backward-paragraph ()
  "Test that backward-paragraph at first position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 50)
    (let ((this-command 'backward-paragraph))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-bottom-scroll-up-command ()
  "Test that scroll-up-command at last position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 199)
    (let ((this-command 'scroll-up-command))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-top-scroll-down-command ()
  "Test that scroll-down-command at first position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 50)
    (let ((this-command 'scroll-down-command))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-bottom-end-of-buffer ()
  "Test that end-of-buffer at last position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 199)
    (let ((this-command 'end-of-buffer))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))

(ert-deftest soft-narrow-guard-top-beginning-of-buffer ()
  "Test that beginning-of-buffer at first position is suppressed."
  (soft-narrow-test--with-buffer 20 buf
    (soft-narrow-to-region 50 200)
    (goto-char 50)
    (let ((this-command 'beginning-of-buffer))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'ignore)))))


;; Property Preservation Tests
;; Oracle-identified gap: soft-narrow--apply-properties must not destroy
;; existing text properties set by other packages.

(ert-deftest soft-narrow-preserves-existing-read-only-property ()
  "Test that existing `read-only' text properties survive narrow/widen cycle."
  (soft-narrow-test--with-buffer 50 buf
    ;; Set a read-only property at a specific position (simulating
    ;; another package's state)
    (put-text-property 150 200 'read-only t)
    (soft-narrow-to-region 100 300)
    (soft-narrow-widen)
    ;; Original read-only property should still be present
    (should (get-char-property 150 'read-only))))

(ert-deftest soft-narrow-preserves-existing-cursor-intangible-property ()
  "Test that existing `cursor-intangible' properties survive narrow/widen cycle."
  (soft-narrow-test--with-buffer 50 buf
    (put-text-property 250 300 'cursor-intangible t)
    (soft-narrow-to-region 100 300)
    (soft-narrow-widen)
    ;; Original cursor-intangible property should survive
    (should (get-char-property 250 'cursor-intangible))))

(ert-deftest soft-narrow-preserves-non-t-read-only-value ()
  "Test that non-t `read-only' values (e.g., `'special) survive.
Oracle-identified gap: `text-property-any ... t' missed non-t
property values.  Now using `text-property-not-all'.
This test verifies that a `read-only' value of `'other-package'
survives the narrow/widen cycle."
  (soft-narrow-test--with-buffer 50 buf
    (put-text-property 150 200 'read-only 'other-package)
    (soft-narrow-to-region 50 300)
    (soft-narrow-widen)
    (should (eq 'other-package
                (get-char-property 150 'read-only)))))

(ert-deftest soft-narrow-preserves-visible-region-properties-during-narrow ()
  "Test that existing properties in the visible region survive during active narrow.
Oracle-identified gap: `remove-list-of-text-properties' on the entire buffer
stripped properties from the visible [l,r) region during active narrow.
`soft-narrow--restore-visible-properties' now restores them."
  (soft-narrow-test--with-buffer 50 buf
    ;; Set a property inside what will be the visible region
    (put-text-property 200 250 'read-only 'important)
    (soft-narrow-to-region 100 300)
    ;; Property should STILL be present during the narrow
    (should (eq 'important
                (get-char-property 200 'read-only)))
    (soft-narrow-widen)
    ;; And after widen too
    (should (eq 'important
                (get-char-property 200 'read-only)))))

(ert-deftest soft-narrow-ownership-reset-on-external-mode-toggle ()
  "Test that ownership is released when user toggles mode externally.
When soft-narrow owns `cursor-intangible-mode' and the user manually
turns it off, `cursor-intangible-mode-hook' detects the toggle and
releases ownership immediately.  If the user then re-enables the mode,
soft-narrow does NOT disable it on final widen because ownership
was already released."
  (soft-narrow-test--with-buffer 50 buf
    ;; Soft-narrow enables cursor-intangible-mode and claims ownership
    (soft-narrow-to-region 100 300)
    (should (bound-and-true-p cursor-intangible-mode))
    (should soft-narrow--owns-cursor-intangible)
    ;; User manually disables the mode (external toggle)
    (cursor-intangible-mode -1)
    ;; Hook should have released ownership immediately
    (should-not soft-narrow--owns-cursor-intangible)
    ;; User re-enables the mode independently
    (cursor-intangible-mode 1)
    ;; Ownership was already released, so this is user-owned
    (should-not soft-narrow--owns-cursor-intangible)
    ;; Final widen: mode should survive since soft-narrow
    ;; no longer owns it
    (soft-narrow-widen)
    (should (bound-and-true-p cursor-intangible-mode))))

(ert-deftest soft-narrow-ownership-reclaims-on-external-off ()
  "Test that ownership is re-claimed when soft-narrow needs the mode again.
If the user turns the mode off (ownership released via hook) but
soft-narrow then needs it for another narrow, it re-enables and
re-claims ownership."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    (should soft-narrow--owns-cursor-intangible)
    ;; User turns mode off
    (cursor-intangible-mode -1)
    (should-not soft-narrow--owns-cursor-intangible)
    ;; Second narrow: soft-narrow needs the mode, enables it,
    ;; claims fresh ownership
    (soft-narrow-to-region 150 250)
    (should soft-narrow--owns-cursor-intangible)
    ;; Final widen should disable since we own it
    (soft-narrow-widen)
    (soft-narrow-widen)
    (should-not (bound-and-true-p cursor-intangible-mode))))


;; cursor-intangible-mode Ownership Tests

(ert-deftest soft-narrow-preserves-pre-existing-cursor-intangible-mode ()
  "Test that pre-existing `cursor-intangible-mode' is not disabled on widen.
When the user enabled cursor-intangible-mode before soft-narrowing,
soft-narrow must not turn it off after the final widen."
  (soft-narrow-test--with-buffer 50 buf
    ;; Simulate user enabling cursor-intangible-mode independently
    (cursor-intangible-mode 1)
    (should (bound-and-true-p cursor-intangible-mode))
    (soft-narrow-to-region 100 300)
    (soft-narrow-widen)
    ;; Mode should still be active — soft-narrow didn't own it
    (should (bound-and-true-p cursor-intangible-mode))))

(ert-deftest soft-narrow-major-mode-change-cleans-buffer-state ()
  "Test that changing major mode releases markers, hooks, ownership, and overlays."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    (soft-narrow-to-region 150 250)
    (let ((markers (mapcan (lambda (frame) (list (car frame) (cdr frame)))
                           soft-narrow--stack)))
      (text-mode)
      (should-not soft-narrow--stack)
      (should-not soft-narrow--cached-intersection)
      (should-not soft-narrow--before-overlay)
      (should-not soft-narrow--after-overlay)
      (should-not soft-narrow--owns-cursor-intangible)
      (should-not (bound-and-true-p cursor-intangible-mode))
      (should-not (memq (function soft-narrow--cleanup) change-major-mode-hook))
      (dolist (marker markers)
        (should-not (marker-position marker))))))

(ert-deftest soft-narrow-base-buffer-narrowing-is-local ()
  "Test that narrowing a base buffer leaves its indirect sibling unchanged."
  (let ((base (generate-new-buffer " *soft-narrow-base*"))
        sibling)
    (unwind-protect
        (progn
          (with-current-buffer base
            (insert (make-string 1000 ?x))
            (setq sibling (clone-indirect-buffer " *soft-narrow-sibling*" nil))
            (soft-narrow-to-region 100 300)
            (should (get-char-property 50 (quote cursor-intangible))))
          (with-current-buffer sibling
            (should-not (soft-narrow-active-p))
            (should-not (get-char-property 50 (quote cursor-intangible)))))
      (when (buffer-live-p sibling) (kill-buffer sibling))
      (when (buffer-live-p base) (kill-buffer base)))))

(ert-deftest soft-narrow-indirect-buffer-narrowing-is-local ()
  "Test indirect narrowing isolation and synchronization after shared edits."
  (let ((base (generate-new-buffer " *soft-narrow-indirect-base*"))
        indirect sibling)
    (unwind-protect
        (progn
          (with-current-buffer base
            (insert (make-string 1000 ?x))
            (setq indirect (clone-indirect-buffer " *soft-narrow-indirect-one*" nil))
            (setq sibling (clone-indirect-buffer " *soft-narrow-indirect-two*" nil)))
          (with-current-buffer indirect
            (soft-narrow-to-region 100 300)
            (should (get-char-property 50 (quote read-only))))
          (with-current-buffer base
            (should-not (soft-narrow-active-p))
            (should-not (get-char-property 50 (quote read-only)))
            (goto-char (point-min))
            (insert "XX"))
          (with-current-buffer sibling
            (should-not (soft-narrow-active-p))
            (should-not (get-char-property 50 (quote read-only))))
          (with-current-buffer indirect
            (should (equal (soft-narrow-region-bounds) (quote (102 . 302))))
            (should (= (overlay-end soft-narrow--before-overlay) 102))
            (should (= (overlay-start soft-narrow--after-overlay) 302))
            (goto-char 101)
            (soft-narrow--clamp-point)
            (should (= (point) 102))
            (should (equal soft-narrow--cached-intersection (quote (102 . 302))))
            (let ((this-command (quote backward-char)))
              (soft-narrow--guard-boundary)
              (should (eq this-command (function ignore))))))
      (when (buffer-live-p indirect) (kill-buffer indirect))
      (when (buffer-live-p sibling) (kill-buffer sibling))
      (when (buffer-live-p base) (kill-buffer base)))))

(ert-deftest soft-narrow-org-commands-load-dependencies ()
  "Test that org commands work without pre-loading org.
Oracle-identified gap: on `emacs -Q', org-narrow commands
fails with `void-function' because org is not loaded."
  (skip-unless (locate-library "org"))
  (skip-unless (locate-library "org-element"))
  (let ((buf (generate-new-buffer " *soft-narrow-org-load-test*")))
    (unwind-protect
        (with-current-buffer buf
          (org-mode)
          (insert "* Heading\nsome text\n")
          (goto-char (point-min))
          ;; org-to-subtree should load org automatically
          (soft-narrow-org-to-subtree)
          (should (soft-narrow-active-p))
          (soft-narrow-widen)
          ;; org-to-block should load org automatically
          (insert "#+begin_example\nblock text\n#+end_example\n")
          (goto-char (point-min))
          (forward-line 1)
          (soft-narrow-org-to-block)
          (should (soft-narrow-active-p))
          (soft-narrow-widen))
      (kill-buffer buf))))

;; Cache Refresh After Edit Tests
;; Regression: editing inside the visible region shifts the stack markers,
;; so the cached integer intersection must be refreshed via
;; `after-change-functions'; otherwise `soft-narrow--clamp-point' and
;; `soft-narrow--guard-boundary' use stale bounds.

(ert-deftest soft-narrow-cache-refresh-after-insert ()
  "Test that inserting inside the region refreshes the cached intersection.
Without the refresh, `soft-narrow--clamp-point' would pull the cursor
back to the old end boundary even though the region grew."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (should (equal soft-narrow--cached-intersection '(200 . 400)))
    ;; Insert 10 chars inside the visible region
    (goto-char 300)
    (insert "XXXXXXXXXX")
    ;; Cache must now reflect the shifted end marker
    (should (equal soft-narrow--cached-intersection '(200 . 410)))
    ;; A cursor at 405 (newly visible) must NOT be clamped back
    (goto-char 405)
    (soft-narrow--clamp-point)
    (should (= (point) 405))))

(ert-deftest soft-narrow-cache-refresh-after-delete ()
  "Test that deleting inside the region refreshes the cached intersection."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (goto-char 250)
    (delete-char 20)
    ;; End marker shrank by 20; cache must follow
    (should (equal soft-narrow--cached-intersection '(200 . 380)))
    ;; Cursor at the old end (399) is now outside; clamp to new r-1
    (goto-char 385)
    (soft-narrow--clamp-point)
    (should (= (point) 379))))

(ert-deftest soft-narrow-guard-uses-refreshed-bounds ()
  "Test that the boundary guard respects bounds updated after an edit.
After growing the region by editing inside it, movement toward the new
end must NOT be suppressed."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (goto-char 300)
    (insert "YYYYYYYYYY")
    ;; 405 is now well inside the region (200..410)
    (goto-char 405)
    (let ((this-command 'forward-char))
      (soft-narrow--guard-boundary)
      (should (eq this-command 'forward-char)))))

(ert-deftest soft-narrow-cache-refresh-hook-cleanup ()
  "Test that the `after-change-functions' refresh hook is removed on widen."
  (soft-narrow-test--with-buffer 50 buf
    (soft-narrow-to-region 100 300)
    (should (memq #'soft-narrow--refresh-intersection
                  (buffer-local-value 'after-change-functions buf)))
    (soft-narrow-widen)
    (should-not (memq #'soft-narrow--refresh-intersection
                      (buffer-local-value 'after-change-functions buf)))))


;; Real-Restriction Preservation Tests
;; Regression: `soft-narrow-to-defun' / `soft-narrow-to-page' must not
;; discard a user's real `narrow-to-region' restriction via a bare `widen'.

(ert-deftest soft-narrow-to-defun-preserves-real-restriction ()
  "Test that `soft-narrow-to-defun' keeps an active real narrowing intact."
  (let ((buf (generate-new-buffer " *soft-narrow-defun-restriction*")))
    (unwind-protect
        (with-current-buffer buf
          (emacs-lisp-mode)
          (insert "(defun a () 1)\n\n(defun b () 2)\n\n(defun c () 3)\n")
          (narrow-to-region 5 30)
          (goto-char 6)
          (ignore-errors (soft-narrow-to-defun))
          ;; The user's real restriction must survive
          (should (= (point-min) 5))
          (should (= (point-max) 30)))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest soft-narrow-to-page-preserves-real-restriction ()
  "Test that `soft-narrow-to-page' keeps an active real narrowing intact."
  (let ((buf (generate-new-buffer " *soft-narrow-page-restriction*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "P1\n\f\nP2\n\f\nP3\n")
          (narrow-to-region 3 9)
          (goto-char 4)
          (ignore-errors (soft-narrow-to-page))
          (should (= (point-min) 3))
          (should (= (point-max) 9)))
      (when (buffer-live-p buf) (kill-buffer buf)))))
(ert-deftest soft-narrow-to-region-preserves-real-restriction ()
  "Soft narrowing must operate inside, and preserve, a real restriction."
  (let ((buf (generate-new-buffer " *soft-narrow-real-restriction*")))
    (unwind-protect
        (with-current-buffer buf
          (insert "0123456789")
          (narrow-to-region 3 9)
          (soft-narrow-to-region 4 7)
          (should (equal (soft-narrow-region-bounds) (cons 4 7)))
          (should (= (point-min) 3))
          (should (= (point-max) 9))
          (should (= (overlay-start soft-narrow--before-overlay) 3))
          (should (= (overlay-end soft-narrow--before-overlay) 4))
          (should (= (overlay-start soft-narrow--after-overlay) 7))
          (should (= (overlay-end soft-narrow--after-overlay) 9))
          ;; Same-length editing remains possible within the soft bounds.
          (goto-char 5)
          (delete-char 1)
          (insert "X")
          (should (eq (char-after 5) ?X))
          (should (equal (soft-narrow-region-bounds) (cons 4 7)))
          ;; Editing outside the soft bounds is blocked by the guard overlay.
          (goto-char 3)
          (should-error (insert "blocked") :type 'text-read-only)
          (soft-narrow-widen)
          (should-not (soft-narrow-region-bounds))
          (should-not (overlayp soft-narrow--before-overlay))
          (should-not (overlayp soft-narrow--after-overlay))
          (should (= (point-min) 3))
          (should (= (point-max) 9)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


;; Point-Clamp-On-Narrow Test
;; Regression: narrowing must leave point inside the visible region even
;; for non-interactive callers (matching `narrow-to-region').

(ert-deftest soft-narrow-clamps-point-into-region-on-narrow ()
  "Test that `soft-narrow-to-region' moves point into the visible region.
If point was in what becomes a blocked area, it must be pulled inside."
  (soft-narrow-test--with-buffer 100 buf
    ;; Point before the region -> clamps up to l
    (goto-char 50)
    (soft-narrow-to-region 200 400)
    (should (= (point) 200))
    (soft-narrow-widen)
    ;; Point after the region -> clamps down to r-1
    (goto-char 800)
    (soft-narrow-to-region 200 400)
    (should (= (point) 399))
    (soft-narrow-widen)
    ;; Point already inside -> unchanged
    (goto-char 300)
    (soft-narrow-to-region 200 400)
    (should (= (point) 300))))

;; Empty Greater Element Test
;; Regression: an empty greater element has nil :contents-begin/-end;
;; `soft-narrow-org-to-element' must not pass nil to
;; `soft-narrow-to-region' (which errored with wrong-type-argument).

(ert-deftest soft-narrow-org-to-element-empty-greater-element ()
  "Test `soft-narrow-org-to-element' on an empty greater element.
Falls back to narrowing the whole element rather than erroring."
  :tags '(org-mode)
  (when (and (require 'org nil t) (require 'org-element nil t))
    (let ((buf (generate-new-buffer " *soft-narrow-org-empty*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "#+begin_center\n#+end_center\n")
            (goto-char 1)
            ;; Must not error
            (soft-narrow-org-to-element)
            (should (soft-narrow-active-p))
            (let ((intersection (soft-narrow--compute-intersection)))
              (should intersection)
              (should (= (car intersection) 1))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

;; Real-Restriction Escape Hatch Tests
;; soft-narrow does not restrict point-min/point-max, so buffer-scanning
;; commands ignore the narrowing.  `soft-narrow-with-restriction' applies
;; a real temporary `narrow-to-region' so such commands can be scoped.

(ert-deftest soft-narrow-region-bounds-accessor ()
  "Test that `soft-narrow-region-bounds' reports active zero-width bounds."
  (soft-narrow-test--with-buffer 100 buf
    (should-not (soft-narrow-region-bounds))
    (soft-narrow-to-region 200 400)
    (should (equal (soft-narrow-region-bounds) (quote (200 . 400))))
    (soft-narrow-to-region 250 350)
    (should (equal (soft-narrow-region-bounds) (quote (250 . 350))))
    (soft-narrow-to-region 600 700)
    (should (equal (soft-narrow-region-bounds) (quote (600 . 600))))))

(ert-deftest soft-narrow-with-restriction-scopes-buffer-scan ()
  "Test that soft-narrow-with-restriction scopes buffer-wide commands.
mark-whole-buffer and count-words see only the soft-narrow region."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    ;; count-words on point-min..point-max sees only the region
    (let ((full (count-words (point-min) (point-max)))
          (scoped (soft-narrow-with-restriction
                   (count-words (point-min) (point-max)))))
      (should (< scoped full)))
    ;; mark-whole-buffer scopes to the region
    (soft-narrow-with-restriction
      (call-interactively (function mark-whole-buffer)))
    (should (= (region-beginning) 200))
    (should (= (region-end) 400))))

(ert-deftest soft-narrow-with-restriction-restores-restriction ()
  "Test that `soft-narrow-with-restriction' restores the prior restriction.
Both the common no-restriction case and a pre-existing real narrowing
must be restored after the body runs."
  (soft-narrow-test--with-buffer 100 buf
    (soft-narrow-to-region 200 400)
    (let ((pmin (point-min)) (pmax (point-max)))
      (soft-narrow-with-restriction (ignore))
      ;; Full buffer bounds restored
      (should (= (point-min) pmin))
      (should (= (point-max) pmax)))
    ;; A pre-existing real restriction is preserved
    (narrow-to-region 150 500)
    (soft-narrow-with-restriction (ignore))
    (should (= (point-min) 150))
    (should (= (point-max) 500))
    (widen)))

(ert-deftest soft-narrow-with-restriction-noop-when-inactive ()
  "Test that `soft-narrow-with-restriction' is a passthrough when inactive."
  (soft-narrow-test--with-buffer 100 buf
    (should-not (soft-narrow-active-p))
    (let ((pmin (point-min)) (pmax (point-max)))
      (let ((scanned (soft-narrow-with-restriction
                      (cons (point-min) (point-max)))))
        ;; Body sees the full buffer (no narrowing applied)
        (should (= (car scanned) pmin))
        (should (= (cdr scanned) pmax))))))

(ert-deftest soft-narrow-execute-keybinding ()
  "Test that `soft-narrow-mode' binds C-x n x to `soft-narrow-execute'."
  (let ((buf (generate-new-buffer " *soft-narrow-execute-test*")))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-mode 1)
          (should (eq (key-binding [?\C-x ?n ?x]) 'soft-narrow-execute))
          (soft-narrow-mode 0))
      (when (buffer-live-p buf) (kill-buffer buf)))))

(ert-deftest soft-narrow-org-export-scoped ()
  "Test that org export wrapped in the escape hatch is scoped to the region.
The reported failure: exporting while soft-narrowed leaked the whole
buffer.  `soft-narrow-with-restriction' scopes export to the subtree."
  :tags '(org-mode)
  (when (and (require 'org nil t)
             (require 'ox nil t)
             (require 'ox-ascii nil t))
    (let ((buf (generate-new-buffer " *soft-narrow-org-export*")))
      (unwind-protect
          (with-current-buffer buf
            (org-mode)
            (insert "* Heading A\nContent A.\n"
                    "* Heading B\nContent B.\n"
                    "* Heading C\nContent C.\n")
            (goto-char 1)
            (soft-narrow-org-to-subtree)
            ;; Unscoped export leaks the other headings
            (let ((leaked (org-export-as 'ascii)))
              (should (string-match-p "Heading B" leaked)))
            ;; Scoped export sees only Heading A
            (let ((scoped (soft-narrow-with-restriction (org-export-as 'ascii))))
              (should (string-match-p "Heading A" scoped))
              (should-not (string-match-p "Heading B" scoped))
              (should-not (string-match-p "Heading C" scoped))))
        (when (buffer-live-p buf) (kill-buffer buf))))))

(ert-deftest soft-narrow-rejects-insertion-at-absolute-buffer-edges ()
  "Reject repeated insertion holes without installing a persistent guard."
  (with-temp-buffer
    (insert "abcdef")
    (soft-narrow-to-region 3 5)
    (dotimes (_ 2)
      (goto-char (point-min))
      (should-error (insert "L") :type (quote text-read-only))
      (should-not before-change-functions)
      (goto-char (point-max))
      (should-error (insert "R") :type (quote text-read-only))
      (should-not before-change-functions))
    (should (equal (buffer-string) "abcdef"))))

  (ert-deftest soft-narrow-zero-and-disjoint-reject-absolute-edge-insertions ()
    "Reject absolute-edge insertions for zero-width and disjoint intersections."
    (dolist (setup (list (lambda () (soft-narrow-to-region 3 3))
                         (lambda ()
                           (soft-narrow-to-region 2 3)
                           (soft-narrow-to-region 5 6))))
      (with-temp-buffer
        (insert "abcdef")
        (funcall setup)
        (should (= (car (soft-narrow-region-bounds))
                   (cdr (soft-narrow-region-bounds))))
        (goto-char (point-min))
        (should-error (insert "L") :type (quote text-read-only))
        (goto-char (point-max))
        (should-error (insert "R") :type (quote text-read-only))
        (should (equal (buffer-string) "abcdef")))))

  (ert-deftest soft-narrow-visible-end-insertion-resynchronizes-overlays ()
    "Keep bounds and overlays synchronized after insertion at visible END."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region 3 5)
      (goto-char 5)
      (insert "X")
      (should (equal (soft-narrow-region-bounds) (quote (3 . 6))))
      (should (equal soft-narrow--cached-intersection (quote (3 . 6))))
      (should (= (overlay-start soft-narrow--after-overlay) 6))
      (should (= (overlay-end soft-narrow--after-overlay) (point-max)))
      (should-not (get-char-property 5 (quote read-only)))
      (should (get-char-property 6 (quote read-only)))))

  (ert-deftest soft-narrow-full-buffer-insertion-keeps-overlays-dormant ()
    "Keep both persistent overlays empty after editing a full-buffer region."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region (point-min) (point-max))
      (goto-char 4)
      (insert "X")
      (should (equal (soft-narrow-region-bounds)
                     (cons (point-min) (point-max))))
      (dolist (overlay (list soft-narrow--before-overlay
                             soft-narrow--after-overlay))
        (should (= (overlay-start overlay) (point-min)))
        (should (= (overlay-end overlay) (point-min))))
      (should-not (get-char-property 4 (quote read-only)))))

  (ert-deftest soft-narrow-global-disable-continues-after-cleanup-error ()
    "Clean every active buffer before re-signaling the first cleanup error."
    (let ((buf1 (generate-new-buffer " *soft-narrow-cleanup-error-1*"))
          (buf2 (generate-new-buffer " *soft-narrow-cleanup-error-2*"))
          (calls nil)
          (original (symbol-function (quote soft-narrow--cleanup))))
      (unwind-protect
          (progn
            (dolist (buf (list buf1 buf2))
              (with-current-buffer buf
                (insert "abcdef")
                (soft-narrow-to-region 2 5)))
            (cl-letf (((symbol-function (quote soft-narrow--cleanup))
                       (lambda ()
                         (push (current-buffer) calls)
                         (funcall original)
                         (when (eq (current-buffer) buf1)
                           (error "injected cleanup failure")))))
              (should-error (soft-narrow-mode -1)
                            :type (quote error)))
            (dolist (buf (list buf1 buf2))
              (should (memq buf calls))
              (with-current-buffer buf
                (should-not soft-narrow--stack)
                (should-not soft-narrow--before-overlay)
                (should-not soft-narrow--after-overlay))))
        (when (buffer-live-p buf1) (kill-buffer buf1))
        (when (buffer-live-p buf2) (kill-buffer buf2)))))

  (ert-deftest soft-narrow-full-buffer-allows-point-min-insertion ()
    "Allow insertion at point-min when both blocking overlays are dormant."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region (point-min) (point-max))
      (goto-char (point-min))
      (insert "X")
      (should (equal (buffer-string) "Xabcdef"))
      (should (equal (soft-narrow-region-bounds)
                     (cons (point-min) (point-max))))
      (should (equal soft-narrow--cached-intersection
                     (cons (point-min) (point-max))))
      (dolist (overlay (list soft-narrow--before-overlay
                             soft-narrow--after-overlay))
        (should (= (overlay-start overlay) (point-min)))
        (should (= (overlay-end overlay) (point-min))))
      (should-not (overlay-get soft-narrow--before-overlay
                               (quote insert-in-front-hooks)))
      (should-not (overlay-get soft-narrow--after-overlay
                               (quote insert-behind-hooks)))))

  (ert-deftest soft-narrow-prefix-visible-allows-point-min-insertion ()
    "Allow point-min insertion when only the trailing range is blocked."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region (point-min) 5)
      (goto-char (point-min))
      (insert "X")
      (should (equal (buffer-string) "Xabcdef"))
      (should (equal (soft-narrow-region-bounds) (quote (1 . 6))))
      (should (equal soft-narrow--cached-intersection (quote (1 . 6))))
      (should (= (overlay-start soft-narrow--before-overlay) (point-min)))
      (should (= (overlay-end soft-narrow--before-overlay) (point-min)))
      (should (= (overlay-start soft-narrow--after-overlay) 6))
      (should (= (overlay-end soft-narrow--after-overlay) (point-max)))
      (should-not (overlay-get soft-narrow--before-overlay
                               (quote insert-in-front-hooks)))
      (should (overlay-get soft-narrow--after-overlay
                           (quote insert-behind-hooks)))))

  (ert-deftest soft-narrow-suffix-visible-allows-point-max-insertion ()
    "Allow point-max insertion when only the leading range is blocked."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region 3 (point-max))
      (goto-char (point-max))
      (insert "X")
      (should (equal (buffer-string) "abcdefX"))
      (should (equal (soft-narrow-region-bounds) (quote (3 . 8))))
      (should (equal soft-narrow--cached-intersection (quote (3 . 8))))
      (should (= (overlay-start soft-narrow--before-overlay) (point-min)))
      (should (= (overlay-end soft-narrow--before-overlay) 3))
      (should (= (overlay-start soft-narrow--after-overlay) (point-min)))
      (should (= (overlay-end soft-narrow--after-overlay) (point-min)))
      (should (overlay-get soft-narrow--before-overlay
                           (quote insert-in-front-hooks)))
      (should-not (overlay-get soft-narrow--after-overlay
                               (quote insert-behind-hooks)))))

(ert-deftest soft-narrow-initial-failure-rolls-back-state ()
  "Release the first frame and all partial state when setup signals."
  (soft-narrow-test--with-buffer 20 buf
				 (require (quote cursor-sensor))
				 (let ((hook-calls 0)
				       failed-frame)
				   (let ((cursor-intangible-mode-hook
       (list (lambda ()
               (setq hook-calls (1+ hook-calls))
               (unless failed-frame
                 (setq failed-frame (car soft-narrow--stack)))
               (error (if (= hook-calls 1)
                          "initial apply failure"
                        "rollback failure"))))))
  (let ((failure (should-error (soft-narrow-to-region 20 80)
                               :type (quote error))))
    (should (equal (error-message-string failure)
                   "initial apply failure")))
  (should (= hook-calls 2))
  (should failed-frame)
  (should-not (marker-buffer (car failed-frame)))
  (should-not (marker-buffer (cdr failed-frame)))))
				 (should-not soft-narrow--stack)
				 (should-not soft-narrow--cached-intersection)
				 (should-not soft-narrow--before-overlay)
				 (should-not soft-narrow--after-overlay)
				 (should-not soft-narrow--owns-cursor-intangible)
				 (should-not (bound-and-true-p cursor-intangible-mode))
				 (should-not (memq (function soft-narrow--on-cursor-intangible-mode-change)
						   cursor-intangible-mode-hook))
				 (should-not (memq (function soft-narrow--guard-boundary)
						   pre-command-hook))
				 (should-not (memq (function soft-narrow--clamp-point)
						   post-command-hook))
				 (should-not (memq (function soft-narrow--refresh-intersection)
						   after-change-functions))
				 (should-not (memq (function soft-narrow--cleanup)
						   change-major-mode-hook))))

(ert-deftest soft-narrow-stacked-failure-preserves-previous-state ()
  "Restore an existing narrowing when a stacked apply signals."
  (soft-narrow-test--with-buffer 20 buf
				 (soft-narrow-to-region 20 80)
				 (let ((previous-stack soft-narrow--stack)
				       (previous-intersection soft-narrow--cached-intersection)
				       (before-start (overlay-start soft-narrow--before-overlay))
				       (before-end (overlay-end soft-narrow--before-overlay))
				       (after-start (overlay-start soft-narrow--after-overlay))
				       (after-end (overlay-end soft-narrow--after-overlay))
				       (apply-calls 0)
				       failed-frame)
				   (cl-letf (((symbol-function (quote soft-narrow--apply-properties))
					      (lambda ()
						(setq apply-calls (1+ apply-calls))
						(unless failed-frame
						  (setq failed-frame (car soft-narrow--stack)))
						(error (if (= apply-calls 1)
							   "stacked apply failure"
							 "stacked rollback failure")))))
				     (let ((failure (should-error (soft-narrow-to-region 30 70)
								  :type (quote error))))
				       (should (equal (error-message-string failure)
						      "stacked apply failure"))))
				   (should (= apply-calls 2))
				   (should (eq soft-narrow--stack previous-stack))
				   (should (eq soft-narrow--cached-intersection previous-intersection))
				   (should failed-frame)
				   (should-not (marker-buffer (car failed-frame)))
				   (should-not (marker-buffer (cdr failed-frame)))
				   (should (= (overlay-start soft-narrow--before-overlay) before-start))
				   (should (= (overlay-end soft-narrow--before-overlay) before-end))
				   (should (= (overlay-start soft-narrow--after-overlay) after-start))
				   (should (= (overlay-end soft-narrow--after-overlay) after-end))
				   (should soft-narrow--owns-cursor-intangible)
				   (should (bound-and-true-p cursor-intangible-mode))
				   (should (memq (function soft-narrow--guard-boundary)
						 pre-command-hook))
				   (should (memq (function soft-narrow--clamp-point)
						 post-command-hook))
				   (should (memq (function soft-narrow--refresh-intersection)
						 after-change-functions)))))

(ert-deftest soft-narrow-pristine-load-initializes-cursor-hook ()
  "Call the public API without preloading cursor-sensor in a pristine Emacs."
  (let* ((library (locate-library "soft-narrow"))
         (root (file-name-directory library))
         (program (expand-file-name invocation-name invocation-directory))
         (status (call-process
                  program nil nil nil
                  "-Q" "--batch" "-L" root
                  "--eval"
                  "(progn (require 'soft-narrow) (with-temp-buffer (insert \"abc\") (soft-narrow-to-region 1 2) (unless (equal (soft-narrow-region-bounds) '(1 . 2)) (kill-emacs 2))))")))
    (should (equal status 0))))

(progn
  (ert-deftest soft-narrow-partial-stacked-failure-restores-mode-state ()
    "Restore cursor mode ownership after a partially applied stack frame."
    (soft-narrow-test--with-buffer 20 buf
      (require (quote cursor-sensor))
      (soft-narrow-to-region 20 80)
      (cursor-intangible-mode -1)
      (should-not (bound-and-true-p cursor-intangible-mode))
      (should-not soft-narrow--owns-cursor-intangible)
      (let ((hook-calls 0)
            failed-frame)
        (add-hook
         (quote cursor-intangible-mode-hook)
         (lambda ()
           (setq hook-calls (1+ hook-calls))
           (unless failed-frame
             (setq failed-frame (car soft-narrow--stack)))
           (when (= hook-calls 1)
             (error "partial stacked apply failure")))
         nil t)
        (let ((previous-stack soft-narrow--stack)
              (previous-intersection soft-narrow--cached-intersection)
              (previous-before-overlay soft-narrow--before-overlay)
              (previous-after-overlay soft-narrow--after-overlay)
              (before-start (overlay-start soft-narrow--before-overlay))
              (before-end (overlay-end soft-narrow--before-overlay))
              (after-start (overlay-start soft-narrow--after-overlay))
              (after-end (overlay-end soft-narrow--after-overlay))
              (previous-cursor-hook (copy-tree cursor-intangible-mode-hook))
              (previous-pre-hook (copy-tree pre-command-hook))
              (previous-post-hook (copy-tree post-command-hook))
              (previous-change-hook (copy-tree after-change-functions))
              (previous-major-mode-hook (copy-tree change-major-mode-hook)))
          (let ((failure
                 (should-error (soft-narrow-to-region 30 70)
                               :type (quote error))))
            (should (equal (error-message-string failure)
                           "partial stacked apply failure")))
          (should (= hook-calls 1))
          (should (eq soft-narrow--stack previous-stack))
          (should (equal soft-narrow--cached-intersection
                         previous-intersection))
          (should (eq soft-narrow--before-overlay previous-before-overlay))
          (should (eq soft-narrow--after-overlay previous-after-overlay))
          (should (= (overlay-start soft-narrow--before-overlay) before-start))
          (should (= (overlay-end soft-narrow--before-overlay) before-end))
          (should (= (overlay-start soft-narrow--after-overlay) after-start))
          (should (= (overlay-end soft-narrow--after-overlay) after-end))
          (should (equal cursor-intangible-mode-hook previous-cursor-hook))
          (should (equal pre-command-hook previous-pre-hook))
          (should (equal post-command-hook previous-post-hook))
          (should (equal after-change-functions previous-change-hook))
          (should (equal change-major-mode-hook previous-major-mode-hook))
          (should failed-frame)
          (should-not (marker-buffer (car failed-frame)))
          (should-not (marker-buffer (cdr failed-frame)))
          (should-not (bound-and-true-p cursor-intangible-mode))
          (should-not soft-narrow--owns-cursor-intangible)))))
  (ert-deftest soft-narrow-invalid-bounds-do-not-enable-mode ()
      "Reject invalid bounds without mutating narrowing state."
      (when soft-narrow-mode
        (soft-narrow-mode -1))
      (with-temp-buffer
        (let ((failure
               (should-error (soft-narrow-to-region nil 2)
                             :type (quote wrong-type-argument))))
          (should (eq (car failure) (quote wrong-type-argument))))
        (should-not soft-narrow-mode)
        (should-not soft-narrow--stack)
        (should-not soft-narrow--before-overlay)
        (should-not soft-narrow--after-overlay)))
    (progn
  (ert-deftest soft-narrow-interior-edits-skip-overlay-recomputation ()
    "Avoid recomputing marker-tracked geometry for strict interior edits."
    (with-temp-buffer
      (insert "abcdef")
      (soft-narrow-to-region 3 5)
      (let ((compute-calls 0)
            (show-calls 0)
            (compute (symbol-function (quote soft-narrow--compute-intersection)))
            (show (symbol-function (quote soft-narrow--show-overlays))))
        (cl-letf (((symbol-function (quote soft-narrow--compute-intersection))
                   (lambda ()
                     (setq compute-calls (1+ compute-calls))
                     (funcall compute)))
                  ((symbol-function (quote soft-narrow--show-overlays))
                   (lambda (&rest args)
                     (setq show-calls (1+ show-calls))
                     (apply show args))))
          (goto-char 4)
          (insert "XY")
          (delete-char -1)
          (should (= compute-calls 0))
          (should (= show-calls 0))
          (should (equal soft-narrow--cached-intersection (quote (3 . 6))))
          (should (= soft-narrow--cached-modification-tick
                     (buffer-chars-modified-tick)))
          (should (= (overlay-end soft-narrow--before-overlay) 3))
          (should (= (overlay-start soft-narrow--after-overlay) 6))
          (goto-char 6)
          (insert "Z")
          (should (= compute-calls 1))
          (should (= show-calls 1))
          (should (equal soft-narrow--cached-intersection (quote (3 . 7))))))))
  (provide (quote soft-narrow-test))))

;;; soft-narrow-test.el ends here
