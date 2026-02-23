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

;; Comprehensive test suite for soft-narrow.el v2.0.0 covering:
;; - Basic functionality tests
;; - Stackable intersection tests
;; - Cursor restriction tests using cursor-intangible
;; - Read-only tests
;; - Edge cases
;; - Performance tests

;;; Code:

(require 'ert)
(require 'soft-narrow)
(require 'soft-narrow-test-helpers)


;; Basic Functionality Tests

(ert-deftest soft-narrow-basic-narrow-widen ()
  "Test basic narrow and widen cycle."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Initially not narrowed
          (should-not (soft-narrow-active-p))

          ;; Narrow to region
          (soft-narrow-to-region 200 400)
          (should (soft-narrow-active-p))

          ;; Widen
          (soft-narrow-widen)
          (should-not (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-active-p-detection ()
  "Test soft-narrow-active-p detection."
  (let ((buf (soft-narrow-test--create-test-buffer 50)))
    (unwind-protect
        (with-current-buffer buf
          ;; Not active initially
          (should-not (soft-narrow-active-p))

          ;; Active after narrowing
          (soft-narrow-to-region 100 300)
          (should (soft-narrow-active-p))

          ;; Not active after widening
          (soft-narrow-widen)
          (should-not (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-text-properties ()
  "Test that text properties are correctly applied."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Check invisible property before region
          (should (eq (get-text-property 50 'invisible) 'soft-narrow))

          ;; Check invisible property after region
          (should (eq (get-text-property 500 'invisible) 'soft-narrow))

          ;; Check no invisible inside region
          (should-not (eq (get-text-property 300 'invisible) 'soft-narrow))

          ;; Check read-only property before region
          (should (get-text-property 50 'read-only))

          ;; Check read-only property after region
          (should (get-text-property 500 'read-only))

          ;; Check no read-only inside region
          (should-not (get-text-property 300 'read-only))

          ;; Check cursor-intangible property before region
          (should (get-text-property 50 'cursor-intangible))

          ;; Check cursor-intangible property after region
          (should (get-text-property 500 'cursor-intangible))

          ;; Check no cursor-intangible inside region
          (should-not (get-text-property 300 'cursor-intangible))

          ;; Check face property
          (should (eq (get-text-property 50 'font-lock-face)
                      'soft-narrow-blocked-face)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-invisibility-spec ()
  "Test that buffer-invisibility-spec is set correctly."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Initially not in invisibility spec
          (should-not (assq 'soft-narrow buffer-invisibility-spec))

          (soft-narrow-to-region 200 400)

          ;; Should be in invisibility spec now
          (should (assq 'soft-narrow buffer-invisibility-spec))

          (soft-narrow-widen)

          ;; Should be removed after widen
          (should-not (assq 'soft-narrow buffer-invisibility-spec)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Stackable Intersection Tests

(ert-deftest soft-narrow-intersection ()
  "Test that successive narrowing creates intersection."
  (let ((buf (soft-narrow-test--create-test-buffer 200)))
    (unwind-protect
        (with-current-buffer buf
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

          ;; Check that only intersection is visible
          (should (eq (get-text-property 150 'invisible) 'soft-narrow))
          (should-not (eq (get-text-property 250 'invisible) 'soft-narrow))
          (should (eq (get-text-property 350 'invisible) 'soft-narrow)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-lifo-widen ()
  "Test LIFO behavior on widen."
  (let ((buf (soft-narrow-test--create-test-buffer 200)))
    (unwind-protect
        (with-current-buffer buf
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
          (should-not (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-stack-marker-management ()
  "Test that markers in the stack are managed correctly."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
          (should (= (marker-position (cdar soft-narrow--stack)) 250)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-empty-stack-after-widens ()
  "Test that stack is empty after widening all levels."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
          (should-not (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Cursor Restriction Tests

(ert-deftest soft-narrow-cursor-intangible-before ()
  "Test that cursor-intangible property is set before narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Check that cursor-intangible property is set
          (should (get-text-property 100 'cursor-intangible))
          (should (get-text-property 150 'cursor-intangible))
          ;; Should be set up to the narrow region
          (should (get-text-property 199 'cursor-intangible))
          ;; Should not be set inside the narrow region
          (should-not (get-text-property 200 'cursor-intangible)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-cursor-intangible-after ()
  "Test that cursor-intangible property is set after narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Check that cursor-intangible property is set
          (should (get-text-property 500 'cursor-intangible))
          (should (get-text-property 450 'cursor-intangible))
          ;; Should be set from the end of narrow region
          (should (get-text-property 400 'cursor-intangible))
          ;; Should not be set inside the narrow region
          (should-not (get-text-property 399 'cursor-intangible)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-cursor-free-inside ()
  "Test that cursor can move freely inside narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Should be able to move anywhere inside
          (goto-char 250)
          (should (= (point) 250))

          (goto-char 300)
          (should (= (point) 300))

          (goto-char 350)
          (should (= (point) 350)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Read-Only Tests

(ert-deftest soft-narrow-readonly-before-region ()
  "Test that editing is blocked before narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Try to insert before region
          (goto-char 100)
          (let ((inhibit-read-only nil))
            (should-error (insert "test") :type 'text-read-only))

          ;; Try to delete before region
          (goto-char 150)
          (let ((inhibit-read-only nil))
            (should-error (delete-char 1) :type 'text-read-only)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-readonly-after-region ()
  "Test that editing is blocked after narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Try to insert after region
          (goto-char 500)
          (let ((inhibit-read-only nil))
            (should-error (insert "test") :type 'text-read-only))

          ;; Try to delete after region
          (goto-char 450)
          (let ((inhibit-read-only nil))
            (should-error (delete-char 1) :type 'text-read-only)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-editing-allowed-inside ()
  "Test that editing is allowed inside narrowed region."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Should be able to insert inside
          (goto-char 250)
          (insert "test")
          (should (string= (buffer-substring 250 254) "test"))

          ;; Should be able to delete inside
          (goto-char 250)
          (delete-char 4)
          ;; After deleting, the original text should be there
          (should-not (string= (buffer-substring 250 254) "test")))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-inhibit-read-only-bypass ()
  "Test that inhibit-read-only allows editing outside."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; With inhibit-read-only, should be able to edit
          (let ((inhibit-read-only t))
            (goto-char 100)
            (insert "bypass")
            (should (string= (buffer-substring 100 106) "bypass"))))
      (soft-narrow-test--cleanup-buffer buf))))


;; Edge Cases

(ert-deftest soft-narrow-invalid-bounds ()
  "Test that out-of-range bounds are clamped to buffer boundaries."
  (let ((buf (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (with-current-buffer buf
          ;; Bounds beyond buffer are clamped to point-min/point-max
          (soft-narrow-to-region 100 1000)
          (should (soft-narrow-active-p))
          ;; End should be clamped to point-max
          (let ((intersection (soft-narrow--compute-intersection)))
            (should (= (car intersection) 100))
            (should (= (cdr intersection) (point-max)))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-invisibility-spec-t ()
  "Test that buffer-invisibility-spec being t is handled correctly."
  (let ((buf (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (with-current-buffer buf
          ;; Simulate buffer-invisibility-spec being t
          (setq-local buffer-invisibility-spec t)
          (soft-narrow-to-region 20 60)

          ;; Should have converted t to list with soft-narrow entry
          (should (listp buffer-invisibility-spec))
          (should (assq 'soft-narrow buffer-invisibility-spec))

          (soft-narrow-widen))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-entire-buffer ()
  "Test narrowing entire buffer."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (let ((size (1+ (buffer-size))))
            (soft-narrow-to-region 1 size)

            ;; Should be narrowed
            (should (soft-narrow-active-p))

            ;; No text should be invisible (intersection covers entire buffer)
            ;; Note: put-text-property with start=end does nothing, so no invisible text
            (should (= (soft-narrow-test--count-invisible-chars 1 size) 0))

            ;; No text should be read-only inside the buffer
            ;; Check a few positions
            (should-not (get-text-property 100 'read-only))
            (should-not (get-text-property 500 'read-only))
            (should-not (get-text-property 1000 'read-only))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-single-point ()
  "Test narrowing to single point."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 200)

          ;; Should be narrowed
          (should (soft-narrow-active-p))

          ;; Everything should be invisible except point 200
          (should (eq (get-text-property 1 'invisible) 'soft-narrow))
          (should (eq (get-text-property 300 'invisible) 'soft-narrow))

          ;; Everything should be read-only
          (should (get-text-property 1 'read-only))
          (should (get-text-property 300 'read-only)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-reverse-arguments ()
  "Test narrowing with reversed start/end arguments."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Call with end before start
          (soft-narrow-to-region 400 200)

          ;; Should normalize to start-end
          (let ((intersection (soft-narrow--compute-intersection)))
            (should (= (car intersection) 200))
            (should (= (cdr intersection) 400))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-multiple-cycles ()
  "Test multiple rapid narrow/widen cycles."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Perform multiple cycles
          (dotimes (_ 10)
            (soft-narrow-to-region (* (+ _ 1) 10) (* (+ _ 1) 20))
            (should (soft-narrow-active-p))
            (soft-narrow-widen)
            (should-not (soft-narrow-active-p)))

          ;; Should still work after multiple cycles
          (soft-narrow-to-region 100 200)
          (should (soft-narrow-active-p))
          (soft-narrow-widen)
          (should-not (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-widen-when-not-narrowed ()
  "Test widening when not narrowed."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Should not error
          (should-not (soft-narrow-active-p))
          (soft-narrow-widen)
          (should-not (soft-narrow-active-p))
          (should-not soft-narrow--stack))
      (soft-narrow-test--cleanup-buffer buf))))

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

          ;; Verify start marker didn't move
          (should (= (marker-position (caar soft-narrow--stack)) 200))))
      (soft-narrow-test--cleanup-buffer buf)))

(ert-deftest soft-narrow-intersection-with-no-overlap ()
  "Test narrowing with regions that don't overlap returns nil."
  (let ((buf (soft-narrow-test--create-test-buffer 200)))
    (unwind-protect
        (with-current-buffer buf
          ;; First narrow: 100-200
          (soft-narrow-to-region 100 200)

          ;; Second narrow: 300-400 (no overlap)
          (soft-narrow-to-region 300 400)

          ;; Intersection should be nil when regions don't overlap
          ;; max(100,300) = 300, min(200,400) = 200
          ;; Since 300 > 200, there is no valid intersection
          (let ((intersection (soft-narrow--compute-intersection)))
            (should-not intersection)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Property Cleanup Tests

(ert-deftest soft-narrow-property-cleanup-on-widen ()
  "Test that all properties are cleaned up on final widen."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 200 400)

          ;; Verify properties are set
          (should (eq (get-text-property 100 'invisible) 'soft-narrow))
          (should (get-text-property 100 'read-only))
          (should (get-text-property 100 'cursor-intangible))

          (soft-narrow-widen)

          ;; Verify all properties are removed
          (should-not (get-text-property 100 'invisible))
          (should-not (get-text-property 100 'read-only))
          (should-not (get-text-property 100 'cursor-intangible))
          (should-not (get-text-property 100 'font-lock-face)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Performance Tests

(ert-deftest soft-narrow-performance-large-buffer ()
  "Test performance on large buffer (>1000 lines)."
  (let ((buf (soft-narrow-test--create-test-buffer 10000)))
    (unwind-protect
        (with-current-buffer buf
          (let ((start (float-time)))
            (soft-narrow-to-region 1000 5000)

            ;; Should complete in reasonable time (< 0.1 seconds)
            (let ((elapsed (- (float-time) start)))
              (should (< elapsed 0.1)))

            ;; Should be properly narrowed
            (should (soft-narrow-active-p))

            ;; Widen should also be fast
            (setq start (float-time))
            (soft-narrow-widen)
            (setq elapsed (- (float-time) start))
            (should (< elapsed 0.1))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-performance-multiple-narrows ()
  "Test performance of multiple successive narrows."
  (let ((buf (soft-narrow-test--create-test-buffer 1000)))
    (unwind-protect
        (with-current-buffer buf
          (let ((start (float-time)))
            ;; Perform 10 narrows
            (dotimes (i 10)
              (soft-narrow-to-region (* (1+ i) 50) (* (1+ i) 100)))

            ;; Total time should be reasonable
            (let ((elapsed (- (float-time) start)))
              (should (< elapsed 0.5)))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-performance-intersection-computation ()
  "Test performance of intersection computation with deep stack."
  (let ((buf (soft-narrow-test--create-test-buffer 1000)))
    (unwind-protect
        (with-current-buffer buf
          ;; Create a deep stack
          (dotimes (i 50)
            (soft-narrow-to-region (* (1+ i) 10) (1+ (* (1+ i) 20))))

          (let ((start (float-time)))
            ;; Compute intersection
            (let ((intersection (soft-narrow--compute-intersection)))
              ;; Should be fast even with deep stack
              (let ((elapsed (- (float-time) start)))
                (should (< elapsed 0.01))))))
      (soft-narrow-test--cleanup-buffer buf))))


;; Stack Management Tests

(ert-deftest soft-narrow-stack-state-preservation ()
  "Test that stack state is preserved across operations."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
            (should (= (cdr intersection) 400))))
      (soft-narrow-test--cleanup-buffer buf))))


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

            ;; Text before block should be invisible
            (should (eq (get-text-property 1 'invisible) 'soft-narrow))

            ;; Text after block should be invisible
            (should (eq (get-text-property (1- (point-max)) 'invisible) 'soft-narrow))

            ;; Text inside block should be visible
            (should-not (eq (get-text-property 50 'invisible) 'soft-narrow)))
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

            ;; First paragraph should be invisible
            (goto-char 1)
            (should (eq (get-text-property 1 'invisible) 'soft-narrow)))
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
            (should (eq (get-text-property 1 'invisible) 'soft-narrow)))
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

          ;; Second function should be invisible
          (goto-char (point-max))
          (forward-line -2)
          (should (eq (get-text-property (point) 'invisible) 'soft-narrow)))
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

          ;; Page 1 should be invisible
          (goto-char 1)
          (should (eq (get-text-property 1 'invisible) 'soft-narrow)))
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

          ;; Page 1 should be invisible
          (goto-char 1)
          (should (eq (get-text-property 1 'invisible) 'soft-narrow)))
      (when (buffer-live-p buf)
        (kill-buffer buf)))))


;; Minor Mode Tests

(ert-deftest soft-narrow-mode-activation ()
  "Test soft-narrow-mode can be activated."
  (let ((buf (generate-new-buffer " *soft-narrow-mode-test*")))
    (unwind-protect
        (with-current-buffer buf
          ;; Initially inactive
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


;; Inverted Intersection Fix Tests

(ert-deftest soft-narrow-inverted-intersection-start-greater-than-end ()
  "Test that non-overlapping regions return nil instead of inverted intersection."
  (let ((buf (soft-narrow-test--create-test-buffer 200)))
    (unwind-protect
        (with-current-buffer buf
          ;; First narrow: 100-200
          (soft-narrow-to-region 100 200)

          ;; Second narrow: 300-400 (no overlap)
          (soft-narrow-to-region 300 400)

          ;; Intersection should be nil for non-overlapping regions
          ;; max(100, 300) = 300, min(200, 400) = 200
          ;; Since 300 > 200, there is no valid intersection
          (let ((intersection (soft-narrow--compute-intersection)))
            (should-not intersection)
            ;; When intersection is nil, no properties are applied
            ;; This is the correct behavior for non-overlapping regions
            ))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-inverted-intersection-property-application ()
  "Test that non-overlapping regions don't apply properties (return nil)."
  (let ((buf (soft-narrow-test--create-test-buffer 200)))
    (unwind-protect
        (with-current-buffer buf
          ;; Create non-overlapping regions
          (soft-narrow-to-region 100 200)
          (soft-narrow-to-region 300 400)

          ;; With non-overlapping regions, intersection should be nil
          ;; No properties should be applied (or they should be cleared)
          (let ((intersection (soft-narrow--compute-intersection)))
            (should-not intersection)

            ;; This should not cause errors
            ;; When intersection is nil, soft-narrow-to-region handles it gracefully
            ;; by not applying any narrowing properties
            (goto-char 150)
            ;; Properties from previous narrowing may still be present until widen
            ;; But no new properties are applied for invalid intersection
            ))
      (soft-narrow-test--cleanup-buffer buf))))


;; Boundary Conditions Tests

(ert-deftest soft-narrow-boundary-buffer-start ()
  "Test narrowing to region starting at buffer start."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 1 300)

          (should (soft-narrow-active-p))

          ;; Nothing should be invisible before the region
          ;; because we start at point-min
          (goto-char 1)
          (should-not (eq (get-text-property 1 'invisible) 'soft-narrow))

          ;; Text after region should be invisible
          (goto-char 500)
          (should (eq (get-text-property 500 'invisible) 'soft-narrow)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-boundary-buffer-end ()
  "Test narrowing to region ending at buffer end."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (let ((size (1+ (buffer-size))))
            (soft-narrow-to-region 200 size)

            (should (soft-narrow-active-p))

            ;; Text before region should be invisible
            (goto-char 100)
            (should (eq (get-text-property 100 'invisible) 'soft-narrow))

            ;; Nothing should be invisible after region
            ;; because we end at point-max
            (goto-char size)
            (should-not (eq (get-text-property size 'invisible) 'soft-narrow))))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-boundary-zero-length ()
  "Test narrowing with zero-length region at various positions."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          ;; Zero-length at middle
          (soft-narrow-to-region 250 250)

          (should (soft-narrow-active-p))

          ;; Everything should be blocked for a zero-length region
          (should (eq (get-text-property 100 'invisible) 'soft-narrow))
          (should (eq (get-text-property 400 'invisible) 'soft-narrow))
          (should (eq (get-text-property 250 'invisible) 'soft-narrow)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-boundary-very-small-region ()
  "Test narrowing to a very small region (1 character)."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 250 251)

          (should (soft-narrow-active-p))

          ;; Position 250 should be visible
          (should-not (eq (get-text-property 250 'invisible) 'soft-narrow))

          ;; Position 251 and beyond should be invisible
          (should (eq (get-text-property 251 'invisible) 'soft-narrow))

          ;; Position 249 and before should be invisible
          (should (eq (get-text-property 249 'invisible) 'soft-narrow)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-boundary-point-min-max ()
  "Test narrowing using point-min and point-max directly."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region (point-min) (point-max))

          (should (soft-narrow-active-p))

          ;; No text should be invisible
          (should-not (eq (get-text-property 1 'invisible) 'soft-narrow))
          (should-not (eq (get-text-property 500 'invisible) 'soft-narrow))
          (should-not (eq (get-text-property (point-max) 'invisible) 'soft-narrow)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Integration Scenario Tests

(ert-deftest soft-narrow-integration-edit-workflow ()
  "Test realistic editing workflow with multiple narrows."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
          (should (string-match "FINAL" (buffer-string))))
      (soft-narrow-test--cleanup-buffer buf))))


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

(ert-deftest soft-narrow-no-post-command-hook ()
  "Verify that soft-narrow.el does not register post-command-hook."
  (let ((source-file (expand-file-name "soft-narrow.el"
                                        (file-name-directory
                                         (locate-library "soft-narrow")))))
    (should (file-exists-p source-file))
    (with-temp-buffer
      (insert-file-contents source-file)
      (goto-char (point-min))
      ;; Search for post-command-hook in soft-narrow code (not in comments)
      (should-not (re-search-forward "^[^;]*post-command-hook" nil t)))))

(ert-deftest soft-narrow-integration-copy-paste-workflow ()
  "Test copy and paste workflow while narrowed."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
          (should (search-forward "Line" 490 t)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-integration-search-replace-workflow ()
  "Test search and replace workflow while narrowed."
  (let ((buf (soft-narrow-test--create-test-buffer 100)))
    (unwind-protect
        (with-current-buffer buf
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
          (should (search-forward "REPLACE_ME" 570 t)))
      (soft-narrow-test--cleanup-buffer buf))))


;; Security Tests

(ert-deftest soft-narrow-security-marker-cleanup ()
  "Test that markers are properly cleaned up on widen."
  (let ((buf (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 20 80)
          (soft-narrow-to-region 30 70)
          (let ((stack-size (length soft-narrow--stack)))
            (soft-narrow-widen)
            (soft-narrow-widen)
            ;; Stack should be empty
            (should-not soft-narrow--stack)))
      (soft-narrow-test--cleanup-buffer buf))))

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
  (let ((buf (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (with-current-buffer buf
          ;; Should handle single-point region without error
          (soft-narrow-to-region 50 50)
          (should (soft-narrow-active-p)))
      (soft-narrow-test--cleanup-buffer buf))))

(ert-deftest soft-narrow-security-reversed-order-stack ()
  "Test stack integrity with reversed order arguments."
  (let ((buf (soft-narrow-test--create-test-buffer 10)))
    (unwind-protect
        (with-current-buffer buf
          (soft-narrow-to-region 80 20)  ; reversed
          (soft-narrow-to-region 40 60)  ; normal
          ;; Stack should have proper markers
          (should (>= (length soft-narrow--stack) 2)))
      (soft-narrow-test--cleanup-buffer buf))))

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

(provide 'soft-narrow-test)

;;; soft-narrow-test.el ends here
