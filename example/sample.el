;;; sample.el --- Sample Emacs Lisp file for testing soft-narrow  -*- lexical-binding: t; -*-

;; Try: M-x soft-narrow-mode, then move point to a defun and press C-x n d

(defun greeting (name)
  "Return a greeting string for NAME."
  (format "Hello, %s!" name))

(defun factorial (n)
  "Compute factorial of N."
  (if (<= n 1)
      1
    (* n (factorial (1- n)))))

(defun fizzbuzz (n)
  "Print FizzBuzz up to N."
  (dotimes (i n)
    (let ((num (1+ i)))
      (cond
       ((zerop (mod num 15)) (princ "FizzBuzz\n"))
       ((zerop (mod num 3))  (princ "Fizz\n"))
       ((zerop (mod num 5))  (princ "Buzz\n"))
       (t                    (princ (format "%d\n" num)))))))

(defun fibonacci (n)
  "Return the Nth Fibonacci number."
  (cond
   ((= n 0) 0)
   ((= n 1) 1)
   (t (+ (fibonacci (- n 1))
         (fibonacci (- n 2))))))

;;; sample.el ends here
