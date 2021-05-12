;;; parseable.lisp -- tests for software/parseable.lisp
(defpackage :software-evolution-library/test/parseable
  (:nicknames :sel/test/parseable)
  (:use
   :gt/full
   :software-evolution-library/test/util
   :stefil+
   :software-evolution-library
   :software-evolution-library/utility/range
   :software-evolution-library/software/parseable
   :software-evolution-library/software/lisp
   :software-evolution-library/software/tree-sitter)
  (:import-from :software-evolution-library/software/parseable
                :hash-type
                :parseable)
  (:import-from :software-evolution-library/software/clang :clang)
  (:export :test-parseable))

(in-package :software-evolution-library/test/parseable)

(defsuite test-parseable "Tests of software/parseable")

(deftest mapcar-test ()
  "Test that mapcar on parseable returns parseable."
  (is (typep (mapcar #'identity
                     (make 'parseable :genome (make 'ast)))
             'parseable)))

(deftest ast-hash-tests ()
  ;; Test that ast-hash works
  (let ((values (list 0 1 nil :a 'a '(a . b)
                      "foo" #(1 2 3) #b110101
                      (make-array '(3) :element-type '(unsigned-byte 8))
                      #'car #p"/")))
    (dolist (v values)
      (let ((h (ast-hash v)))
        (is (typep h 'hash-type)
            "Value not hashed to a hash-type: ~a ==> ~a"
            v h)))))

(deftest ast-hash-overflow-test ()
  "Test that ast hash doesn't overflow on a long list."
  (finishes (ast-hash (make-list (expt 2 18) :initial-element "foo"))))

(deftest (test-javascript-source-ranges :long-running t) ()
  (let ((js-files (expand-wildcard #p"javascript/*/*.js")))
    (test-ast-source-ranges-for-files 'javascript js-files
                                      :ignore-indentation t)))

(deftest (test-python-source-ranges :long-running t) ()
  (let ((py-files (expand-wildcard #p"python/*/*.py")))
    ;; We ignore whitespace here because
    (test-ast-source-ranges-for-files 'python py-files
                                      :ignore-indentation t)))

(deftest test-lisp-source-ranges ()
  (let ((lisp-files (expand-wildcard #p"lisp*/*.lisp")))
    (test-ast-source-ranges-for-files 'lisp lisp-files)))

(deftest (test-clang-source-ranges :long-running t) ()
  (let ((c-files (expand-wildcard #p"*/*.c")))
    ;; There are a lot of Clang source files and parsing them is slow
    ;; so set a limit. Note the files actually tested are chosen at
    ;; random from the set of all files.
    (test-ast-source-ranges-for-files 'clang c-files :limit 10)))

(define-software test-tree-sitter () ()
                 (:documentation "Mixin for test classes."))

(define-software test-parseable (c test-tree-sitter) ()
                 (:documentation "For testing purposes only."))

(defparameter *preselected-crossover-point* nil "For testing.")
(defmethod select-crossover-points ((a test-parseable) (b test-parseable))
  "For test purposes, choose pre-selected crossover point."
  *preselected-crossover-point*)

(deftest crossover-test ()
  (when-let* ((soft1 (from-file (make-instance 'test-parseable)
                      (merge-pathnames "parseable/variety2.c"
                                       (make-pathname :directory +etc-dir+))))
              (soft2 (from-file (make-instance 'test-parseable)
                      (merge-pathnames "parseable/variety.c"
                                  (make-pathname :directory +etc-dir+))))
              (switch-statement
               (find 'c-switch-statement (genome soft1)
                     :key (lambda (x) (class-name (class-of x)))))
              (crossover-pt (ast-path (genome soft1) switch-statement))
              (*preselected-crossover-point* crossover-pt)
              (new-a (crossover soft1 soft2))
              (pos (search "case 2:" (source-text (genome new-a)))))
    (is (integerp pos))))
