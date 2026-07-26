;;; compare.el --- Compare soft-narrow with fancy-narrow  -*- lexical-binding: t; -*-

(progn
  (require 'cl-lib)
  (require 'soft-narrow)
  (require 'fancy-narrow)

  (defconst soft-narrow-benchmark-fancy-commit
    "c9b3363752c09045b8ce7a2635afae42d2ae63c7")

  (defun soft-narrow-benchmark--natural (name default)
    (let ((value (getenv name)))
      (if (and value (string-match-p "\\`[1-9][0-9]*\\'" value))
          (string-to-number value)
        default)))

  (defun soft-narrow-benchmark--make-buffer (bytes)
    (let ((buffer (generate-new-buffer " *soft-narrow-benchmark*")))
      (with-current-buffer buffer
        (buffer-disable-undo)
        (fundamental-mode)
        (insert-char ?x bytes)
        (set-buffer-modified-p nil))
      buffer))

  (defun soft-narrow-benchmark--bounds (bytes)
    (cons (1+ (/ bytes 4))
          (1+ (* 3 (/ bytes 4)))))

  (defun soft-narrow-benchmark--narrow (implementation beg end)
    (pcase implementation
      ('soft-narrow (soft-narrow-to-region beg end))
      ('fancy-narrow (fancy-narrow-to-region beg end))))

  (defun soft-narrow-benchmark--widen (implementation)
    (pcase implementation
      ('soft-narrow (soft-narrow-widen))
      ('fancy-narrow (fancy-widen))))

  (defun soft-narrow-benchmark--sample
      (implementation scenario bytes edit-iterations)
    (let ((buffer (soft-narrow-benchmark--make-buffer bytes))
          (bounds (soft-narrow-benchmark--bounds bytes))
          active
          elapsed)
      (unwind-protect
          (with-current-buffer buffer
            (let ((inhibit-message t)
                  (message-log-max nil))
              (pcase scenario
                ('setup
                 (garbage-collect)
                 (let ((started (current-time)))
                   (soft-narrow-benchmark--narrow
                    implementation (car bounds) (cdr bounds))
                   (setq elapsed
                         (float-time (time-subtract (current-time) started)))
                   (setq active t)))
                ('steady-edit
                 (soft-narrow-benchmark--narrow
                  implementation (car bounds) (cdr bounds))
                 (setq active t)
                 (goto-char (/ (+ (car bounds) (cdr bounds)) 2))
                 (garbage-collect)
                 (let ((started (current-time)))
                   (dotimes (_ edit-iterations)
                     (insert "y")
                     (delete-char -1))
                   (setq elapsed
                         (/ (float-time
                             (time-subtract (current-time) started))
                            edit-iterations))))
                ('widen
                 (soft-narrow-benchmark--narrow
                  implementation (car bounds) (cdr bounds))
                 (setq active t)
                 (garbage-collect)
                 (let ((started (current-time)))
                   (soft-narrow-benchmark--widen implementation)
                   (setq elapsed
                         (float-time (time-subtract (current-time) started)))
                   (setq active nil))))))
        (when (buffer-live-p buffer)
          (with-current-buffer buffer
            (when active
              (ignore-errors
                (soft-narrow-benchmark--widen implementation))))
          (kill-buffer buffer)))
      elapsed))

  (defun soft-narrow-benchmark--collect
      (implementation scenario bytes warmups samples edit-iterations)
    (dotimes (_ warmups)
      (soft-narrow-benchmark--sample
       implementation scenario bytes edit-iterations))
    (let (values)
      (dotimes (_ samples)
        (push (soft-narrow-benchmark--sample
               implementation scenario bytes edit-iterations)
              values))
      (nreverse values)))

  (defun soft-narrow-benchmark--stats (values)
    (let* ((sorted (sort (copy-sequence values) #'<))
           (count (length sorted))
           (middle (/ count 2))
           (median (if (cl-oddp count)
                       (nth middle sorted)
                     (/ (+ (nth (1- middle) sorted) (nth middle sorted))
                        2.0)))
           (p95-index (min (1- count) (1- (ceiling (* count 0.95))))))
      (list :min (car sorted)
            :median median
            :mean (/ (apply #'+ sorted) count)
            :p95 (nth p95-index sorted))))

  (defun soft-narrow-benchmark--print-stats
      (scenario implementation stats samples iterations)
    (princ
     (format "%s\t%s\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\n"
             scenario implementation
             (* 1000000.0 (plist-get stats :min))
             (* 1000000.0 (plist-get stats :median))
             (* 1000000.0 (plist-get stats :mean))
             (* 1000000.0 (plist-get stats :p95))
             samples iterations)))

  (defun soft-narrow-benchmark-run ()
    (let ((bytes (soft-narrow-benchmark--natural
                  "BENCHMARK_BUFFER_BYTES" (* 10 1024 1024)))
          (warmups (soft-narrow-benchmark--natural "BENCHMARK_WARMUPS" 3))
          (samples (soft-narrow-benchmark--natural "BENCHMARK_SAMPLES" 15))
          (edit-iterations
           (soft-narrow-benchmark--natural "BENCHMARK_EDIT_ITERATIONS" 2000)))
      (princ (format "Emacs: %s\nSystem: %s\nBuffer bytes: %d\nWarmups: %d\nSamples: %d\nEdit iterations: %d\nFancy-narrow commit: %s\nMode: fundamental-mode (non-displayed batch buffers)\n\n"
                     emacs-version system-configuration bytes warmups samples
                     edit-iterations soft-narrow-benchmark-fancy-commit))
      (princ "scenario\timplementation\tmin_us/op\tmedian_us/op\tmean_us/op\tp95_us/op\tsamples\titerations/op\n")
      (dolist (scenario '(setup steady-edit widen))
        (let* ((iterations (if (eq scenario 'steady-edit) edit-iterations 1))
               (fancy (soft-narrow-benchmark--stats
                       (soft-narrow-benchmark--collect
                        'fancy-narrow scenario bytes warmups samples
                        edit-iterations)))
               (soft (soft-narrow-benchmark--stats
                      (soft-narrow-benchmark--collect
                       'soft-narrow scenario bytes warmups samples
                       edit-iterations))))
          (soft-narrow-benchmark--print-stats
           scenario 'fancy-narrow fancy samples iterations)
          (soft-narrow-benchmark--print-stats
           scenario 'soft-narrow soft samples iterations)
          (princ (format "# %s soft/fancy median ratio: %.6f\n" scenario (/ (plist-get soft :median) (plist-get fancy :median))))))))

  (soft-narrow-benchmark-run))

;;; compare.el ends here
