;;;; clang.lisp --- Clang representation.
(defpackage :software-evolution-library/test/clang
  (:nicknames :sel/test/clang)
  (:use
   :gt/full
   :cl-store
   #+gt :testbot
   :software-evolution-library/test/util
   :software-evolution-library/test/util-clang
   :stefil+
   :software-evolution-library
   :software-evolution-library/software/parseable
   :software-evolution-library/software/clang
   :software-evolution-library/software/clang-expression
   :software-evolution-library/components/fodder-database)
  (:export :test-clang))
(in-package :software-evolution-library/test/clang)
(in-readtable :curry-compose-reader-macros)
(defsuite test-clang "Clang representation." (clang-available-p))

(defvar *huf* nil "Holds the huf software object.")

(define-constant +switch-macros-dir+ (append +etc-dir+ (list "switch-macros"))
  :test #'equalp
  :documentation "Path to the switch-macros example.")

(define-constant +simple-macros-dir+ (append +etc-dir+ (list "simple-macros"))
  :test #'equalp
  :documentation "Path to the simple-macros example.")

(defun switch-macros-dir (filename)
  (make-pathname :name (pathname-name filename)
                 :type (pathname-type filename)
                 :directory +switch-macros-dir+))

(defun simple-macros-dir (filename)
  (make-pathname :name (pathname-name filename)
                 :type (pathname-type filename)
                 :directory +simple-macros-dir+))

(defixture switch-macros-clang
  (:setup
   (setf *soft*
         (from-file (make-instance 'clang)
                    (switch-macros-dir "switch-macros.c"))))
  (:teardown
   (setf *soft* nil)))

(defixture simple-macros-clang
  (:setup
   (setf *soft*
         (from-file (make-instance 'clang)
                    (simple-macros-dir "simple-macros.c"))))
  (:teardown
   (setf *soft* nil)))

(deftest simply-able-to-load-a-clang-software-object()
  (with-fixture hello-world-clang
    (is (not (null *hello-world*)))))

(deftest ast-hash-clang ()
  (with-fixture hello-world-clang
    (is (not (null (genome *hello-world*))))
    (is (typep (ast-hash (genome *hello-world*)) '(integer 0)))))

(deftest (genome-change-clears-clang-software-object-fields :long-running) ()
  (with-fixture hello-world-clang
    (is (not (null (stmt-asts *hello-world*))))
    (is (not (null (functions *hello-world*))))
    (is (not (null (prototypes *hello-world*))))
    (is (not (null (includes *hello-world*))))
    ;; The following were already nil, so this test
    ;; is not testing that they were cleared
    (is (null (non-stmt-asts *hello-world*)))
    (is (null (macros *hello-world*)))
    (is (null (fitness *hello-world*)))
    (setf (genome *hello-world*) "")
    (is (null  (asts *hello-world*)))
    (is (null  (stmt-asts *hello-world*)))
    (is (null  (non-stmt-asts *hello-world*)))
    (is (null  (functions *hello-world*)))
    (is (null  (prototypes *hello-world*)))
    (is (null  (includes *hello-world*)))
    (is (null  (macros *hello-world*)))
    (is (null  (fitness *hello-world*)))
    (is (zerop (count-if [#'type-i-file #'ct+-type]
                         (hash-table-values (types *hello-world*)))))))



(deftest asts-are-parsed-lazily ()
  (with-fixture hello-world-clang
    (is (stringp (slot-value *hello-world* 'genome))
        "genome is initially a string")
    (is (typep (genome *hello-world*) 'ast)
        "ASTs are parsed when needed")))

(deftest asts-are-set-on-copy ()
  (with-fixture hello-world-clang
    (let ((new (copy *hello-world*)))
      (is (eq (genome new) (genome *hello-world*))
          "Copy and original share ASTs")

      (apply-mutation new (make-instance 'clang-swap :object new))
      (is (eq (genome new) (genome (copy new)))
          "Additional copies do not cause updates"))))

(deftest (splits-global-and-stmt-asts :long-running) ()
  (with-fixture huf-clang
    (is (find-if [{string= "\"this is an example for huffman encoding\""}
                  #'source-text]
                 (non-stmt-asts *huf*))
        "Ensure known global is in `globals'.")
    (is (find-if [{string= "int i"} #'source-text]
                 (stmt-asts *huf*))
        "Ensure known local variable is in `stmts'.")
    (is (null (find :ParmVar (stmt-asts *huf*)
                    :key #'ast-class))
        "Ensure no ParmVar statement ASTs")
    (is (null (find :Function (stmt-asts *huf*)
                    :key #'ast-class))
        "Ensure no Function statement ASTs")))

(deftest can-compile-clang-software-object ()
  (with-fixture hello-world-clang
    (with-temporary-file (:pathname bin)
      (multiple-value-bind (bin errno stderr stdout src)
          (ignore-phenome-errors
           (phenome *hello-world* :bin bin))
        (declare (ignorable stderr stdout src))
        (is (probe-file bin))
        (is (= 0 errno))))))

(deftest can-apply-mutation-w-value1 ()
  (with-fixture hello-world-clang
    (let* ((variant (copy *hello-world*))
           (stmt1 (stmt-with-text variant
                                  "printf(\"Hello, World!\\n\");")))
      (apply-mutation variant
                      `(clang-replace
                        (:stmt1 . ,stmt1)
                        (:value1 . ,(make-literal 0))))
      (is (different-asts (asts variant) (asts *hello-world*)))
      (is (not (equal (genome-string variant)
                      (genome-string *hello-world*)))))))

(deftest can-apply-mutation-w-value2 ()
  (with-fixture sqrt-clang
    (let* ((variant (copy *sqrt*))
           (integer-constant
            (second (remove-if-not
                     [{equal :IntegerLiteral} #'ast-class]
                     (asts variant)))))
      (apply-mutation variant
                      `(clang-replace
                        (:stmt1 . ,integer-constant)
                        (:value1 . ,(make-literal 0))))
      (is (different-asts (asts variant) (asts *sqrt*)))
      (is (not (equal (genome-string variant)
                      (genome-string *sqrt*))))
      (is (stmt-with-text variant "0")))))

(deftest cut-shortens-a-clang-software-object()
  (with-fixture hello-world-clang
    (let* ((variant (copy *hello-world*))
           (stmt1 (stmt-with-text variant
                                  "printf(\"Hello, World!\\n\");")))
      (apply-mutation variant `(clang-cut (:stmt1 . ,stmt1)))
      (is (different-asts (asts variant)
                          (asts *hello-world*)))
      (is (not (equal (genome-string variant)
                      (genome-string *hello-world*))))
      (is (< (size variant)
             (size *hello-world*))))))

(deftest insert-lengthens-a-clang-software-object()
  (with-fixture hello-world-clang
    (let ((variant (copy *hello-world*))
          (stmt1 (stmt-with-text *hello-world*
                                 "printf(\"Hello, World!\\n\");"))
          (stmt2 (stmt-with-text *hello-world*
                                 "return 0;")))
      (apply-mutation variant
                      `(clang-insert (:stmt1 . ,stmt1) (:stmt2 . ,stmt2)))
      (is (different-asts (asts variant)
                          (asts *hello-world*)))
      (is (not (equal (genome-string variant)
                      (genome-string *hello-world*))))
      (is (> (size variant)
             (size *hello-world*))))))

(deftest swap-changes-a-clang-software-object()
  (with-fixture hello-world-clang
    (let ((variant (copy *hello-world*))
          (stmt1 (stmt-with-text *hello-world*
                                 "printf(\"Hello, World!\\n\");"))
          (stmt2 (stmt-with-text *hello-world*
                                 "return 0;")))
      (apply-mutation variant
                      `(clang-swap (:stmt1 . ,stmt1) (:stmt2 . ,stmt2)))
      (is (different-asts (asts variant)
                          (asts *hello-world*)))
      (is (not (equal (genome-string variant)
                      (genome-string *hello-world*))))
      (is (= (size variant)
             (size *hello-world*))))))

(deftest clang-copies-are-independent ()
  (with-fixture hello-world-clang
    (let ((orig-genome-string (genome-string *hello-world*))
          (variant (copy *hello-world*)))
      (apply-mutation
       variant
       `(clang-cut (:stmt1 . ,(stmt-with-text
                               variant "printf(\"Hello, World!\\n\");"))))
      (is (string= (genome-string *hello-world*)
                   orig-genome-string))
      (is (not (string= (genome-string variant)
                        orig-genome-string))))))

(deftest clang-copies-share-asts ()
  (with-fixture hello-world-clang
    (let ((variant (copy *hello-world*)))
      (is (eq (genome *hello-world*) (genome variant)))
      (is (> (size variant) 0)))))

(deftest clang-mutation-preserves-unmodified-subtrees ()
  (with-fixture hello-world-clang
    (let ((variant (copy *hello-world*)))
      (apply-mutation
       variant
       `(clang-cut (:stmt1 . ,(stmt-with-text
                               variant "printf(\"Hello, World!\\n\");"))))
      (is (equal? (stmt-with-text *hello-world* "return 0;")
                  (stmt-with-text variant "return 0;"))))))

(deftest crossover-clang-software-object-does-not-crash()
  (with-fixture hello-world-clang
    (let* ((variant (crossover (copy *hello-world*) (copy *hello-world*))))
      (is (string/= (genome-string variant) "")))))

(deftest empty-function-body-crossover-does-not-crash ()
  (with-fixture empty-function-body-crossover-bug-clang
    (let ((crossed (crossover *soft* *soft*)))
      (is (string/= (genome-string crossed) "")))))

(deftest select-intraprocedural-pair-does-not-return-null ()
  (with-fixture select-intraprocedural-pair-non-null-clang
    (loop :for i :from 0 :to 100
       :do (multiple-value-bind (stmt1 stmt2)
               (select-intraprocedural-pair *soft*)
             (is (not (null stmt1)))
             (is (not (null stmt2)))))))

(deftest can-serialize-a-clang-software-obj ()
  (with-fixture hello-world-clang
    (with-temporary-file (:pathname store-file)
      (store *hello-world* store-file)
      (is (equalp (genome-string (restore store-file))
                  (genome-string *hello-world*))))))

(deftest clang-ast-source-ranges ()
  (with-fixture hello-world-clang
    (is (equalp (mapcar [#'range-to-list #'cdr]
                        (ast-source-ranges *hello-world*))
                '(((1 . 1)  (10 . 1))
                  ((5 . 1)  (9 . 2))
                  ((5 . 12) (9 . 2))
                  ((6 . 2)  (6 . 28))
                  ((6 . 2)  (6 . 8))
                  ((6 . 2)  (6 . 8))
                  ((6 . 9)  (6 . 26))
                  ((6 . 9)  (6 . 26))
                  ((6 . 9)  (6 . 26))
                  ((8 . 2)  (8 . 11))
                  ((8 . 9)  (8 . 10)))))))


;;; Misc. clang tests

#+failing ;; FIXME: NEW-CLANG-AST not defined on AST-INCLUDES
(deftest able-to-wrap-statements-in-blocks ()
  (with-fixture gcd-wo-curlies-clang
    (let ((var (copy *gcd*)))
      ;; Setup, ensure everything is what we thing it should be.
      (is (eq :BinaryOperator     ; Guard
              (ast-class (stmt-with-text var "a > b"))))
      (is (eq :BinaryOperator     ; Then
              (ast-class (stmt-with-text var "a = a - b;"))))
      (is (eq :BinaryOperator     ; Else
              (ast-class (stmt-with-text var "b = b - a;"))))
      ;; Wrap children and ensure changes are made.

      (setf var (wrap-child var (stmt-with-text var "if (a > b)" :at-start t)
                            1))
      (setf var (wrap-child var (stmt-with-text var "if (a > b)" :at-start t)
                            2))
      (is (eq :BinaryOperator     ; Guard
              (ast-class (stmt-with-text var "a > b"))))
      (is (eq :CompoundStmt       ; Then
              (ast-class (get-parent-ast var
                                         (stmt-with-text var "a = a - b;")))))
      (is (eq :CompoundStmt       ; Then
              (ast-class (get-parent-ast var
                                         (stmt-with-text var "b = b - a;")))))
      ;; Ensure gcd remains unchanged.
      (is (eq :BinaryOperator     ; Guard
              (ast-class (stmt-with-text *gcd* "a > b"))))
      (is (eq :BinaryOperator     ; Then
              (ast-class (stmt-with-text *gcd* "a = a - b;"))))
      (is (eq :BinaryOperator     ; Else
              (ast-class (stmt-with-text *gcd* "b = b - a;")))))))

(deftest clang-headers-parsed-in-order ()
  (with-fixture headers-clang
    ;; TODO: Include "first.c" before include "third.c".

    ;; TODO: Ensure "MAIN" is present.  Presently MAIN is not present
    ;; because it is not used in the immediate source.

    ;; TODO: Ensure "ANOTHER" is not present.  It is defined in
    ;; another file.
    ))

(deftest clang-includes-initialized ()
  (with-fixture headers-clang
    (let ((includes (includes *headers*)))
      (is (listp includes))
      ;; As JR explained, "first.c" is handled
      ;; differently in the old clang front end, in
      ;; the types table, not the includes attribute.
      ;; TODO: determine if it is ok to have "first.c"
      ;; here instead.
      (is (= 3 (length includes)))
      (is (member "\"second.c\"" includes :test #'equal))
      (is (member "\"third.c\"" includes :test #'equal)))))

(deftest clang-macros-initialized ()
  (with-fixture headers-clang
    (let ((macros (macros *headers*)))
      (is (listp macros))
      (is (= 2 (length macros)))
      (is (member "MAIN" (macros *headers*)
                  :key #'macro-name :test #'string=))
      (is (member "ANOTHER" (macros *headers*)
                  :key #'macro-name :test #'string=)))))

(deftest clang-types-initialized ()
  (with-fixture headers-clang
    (let ((types (types *headers*)))
      (is (hash-table-p types))
      (is (subsetp (list "bar" "char" "char*" "foo" "int")
                   (mapcar (lambda (s) (remove #\Space s))
                           (sort (mapcar #'type-name (hash-table-values types))
                                 #'string<))
                   :test #'equal)))))

(deftest update-asts-doesnt-duplicate-includes ()
  (with-fixture headers-clang
    ;; each include only appears once in the genome
    ;; (all-matches includes start/end so length is double the number of
    ;; occurrences)
    (is (= 2 (nest (length)
                   (all-matches "#include\\w* \"first.c\"")
                   (genome-string *headers*))))
    (is (= 2 (nest (length)
                   (all-matches "#include\\w* \"third.c\"")
                   (genome-string *headers*))))))

(deftest add-macro-test ()
  (with-fixture hello-world-clang
    (add-macro *hello-world* (make-clang-macro :hash 3656618339188109385
                                               :name "ONE"
                                               :body "ONE 1"))
    (is (equal 1 (length (macros *hello-world*))))
    (is (not (null (search "#define ONE 1" (genome-string *hello-world*)))))))

(deftest find-macro-test ()
  (with-fixture hello-world-clang
    (add-macro *hello-world* (make-clang-macro :hash 3656618339188109385
                                               :name "ONE"
                                               :body "ONE 1"))
    (is (not (null (find-macro *hello-world* 3656618339188109385))))))

(deftest add-type-with-include-test ()
  (with-fixture fib-clang
    (add-type *fib*
              (nest (make-instance 'ct+ :type)
                    (make-instance 'clang-type
                      :qual "FILE *"
                      :i-file "<stdio.h>"
                      :modifiers +pointer+
                      :reqs nil
                      :name "FILE")))
    (is (equal 1 (length (includes *fib*))))))

(deftest add-bad-include-doesnt-change-number-of-asts ()
  (with-fixture hello-world-clang
    (let ((orig-num-asts (size *hello-world*)))
      (add-include *hello-world* "<garbage.h>")
      (is (equal orig-num-asts (size *hello-world*))))))

(deftest add-bad-type-doesnt-change-number-of-asts ()
  (with-fixture hello-world-clang
    (let ((orig-num-asts (size *hello-world*)))
      (add-type *hello-world*
                (nest (make-instance 'ct+ :type)
                      (make-instance 'clang-type
                        :decl "struct printf { chocolate cake; }"
                        :array ""
                        :name "struct printf")))
      (is (equal orig-num-asts (size *hello-world*))))))

(deftest add-new-type-changes-genome-and-types ()
  (with-fixture hello-world-clang
    (let ((orig-genome-str-length (length (genome-string *hello-world*)))
          (orig-num-types (hash-table-count (types *hello-world*)))
          (struct-str "struct printf { chocolate cake; }"))
      (add-type *hello-world*
                (nest (make-instance 'ct+ :type)
                      (make-instance 'clang-type
                        :decl struct-str :name "struct printf")))
      ;; new type gets added to genome
      (is (= (+ orig-genome-str-length (length struct-str)
                (length (genome-string *hello-world*)))))
      (is (search struct-str (genome-string *hello-world*)))
      ;; new type is added to types
      (is (= (1+ orig-num-types) (hash-table-count (types *hello-world*)))))))

(deftest add-bad-macro-doesnt-change-number-of-asts ()
  (with-fixture hello-world-clang
    (let ((orig-num-asts (size *hello-world*)))
      (add-macro *hello-world*
                 (make-clang-macro :name "GARBAGE"
                                   :body "GARBAGE TRASH"
                                   :hash -4794347995631201955))
      (is (equal orig-num-asts (size *hello-world*))))))

(deftest force-include-test ()
  (with-fixture hello-world-clang
    (let ((copy (copy *hello-world*)))
      (force-include copy "<system.h>")
      (force-include copy "<system.h>")
      (is (member "<system.h>" (includes copy) :test #'string=)
          "<system.h> should have been added the software object's includes")
      (is (not (equal (search "<system.h>" (genome-string copy) :from-end nil)
                      (search "<system.h>" (genome-string copy) :from-end t)))
          "<system.h> should have been added twice to the software object"))))

(deftest clang-mutation-targets-default-test ()
  "Ensure mutation-targets returns all stmt asts by default"
  (with-fixture hello-world-clang
    (is (equalp (stmt-asts *hello-world*)
                (mutation-targets *hello-world*)))))

(deftest clang-mutation-targets-filter-test ()
  "Ensure the filter parameter to mutation-targets works as anticipated"
  (with-fixture hello-world-clang
    (is (equalp (remove-if-not #'full-stmt-filter
                               (stmt-asts *hello-world*))
                (mutation-targets *hello-world*
                                  :filter #'full-stmt-filter)))))

(deftest clang-mutation-targets-stmt-pool-test ()
  "Ensure the stmt-pool parameter to mutation-targets works as anticipated"
  (with-fixture hello-world-clang-control-picks
    (let ((*bad-asts* (remove-if-not #'full-stmt-filter
                                     (stmt-asts *hello-world*))))
      (is (equalp (remove-if-not #'full-stmt-filter
                                 (stmt-asts *hello-world*))
                  (mutation-targets *hello-world*
                                    :stmt-pool #'bad-stmts))))))

(deftest clang-mutation-targets-expand-stmt-pool-restart-test ()
  "Ensure the expand-stmt-pool restart works as intended"
  (with-fixture hello-world-clang-control-picks
    (let ((*bad-asts* (remove-if-not #'full-stmt-filter
                                     (stmt-asts *hello-world*))))
      ;; Before invoking the 'expand-stmt-pool filter, the
      ;; stmt pool does not include any full statements.
      ;; After its invocation, all full statements are returned.
      (is (equalp (remove-if-not #'full-stmt-filter
                                 (stmt-asts *hello-world*))
                  (handler-bind
                      ((no-mutation-targets
                        (lambda (c)
                          (declare (ignorable c))
                          (invoke-restart 'expand-stmt-pool))))
                    (mutation-targets *hello-world*
                                      :filter #'full-stmt-filter
                                      :stmt-pool #'bad-stmts)))))))

(deftest clang-pick-general-does-not-throw-test ()
  "Ensure calling pick-general does not throw an exception"
  (with-fixture hello-world-clang
    (is (not (null (pick-general *hello-world* #'stmt-asts))))))

(deftest clang-pick-general-full-stmt-no-matching-test ()
  "Ensure calling pick-general with a full-stmt filter
throws a no-mutation-targets error when there are no full stmts,
e.g. after a bad crossover"
  (with-fixture hello-world-clang-control-picks
    (let ((*bad-asts* (remove-if #'full-stmt-filter
                                 (stmt-asts *hello-world*))))
      (signals no-mutation-targets
               (pick-general *hello-world* #'bad-stmts
                             :filter #'full-stmt-filter)))))

(deftest clang-pick-general-full-stmt-test ()
  "Ensure calling pick-general with a full-stmt filter returns a full
statement pick"
  (with-fixture hello-world-clang-control-picks
    (let ((pick (pick-general *hello-world* #'stmt-asts
                              :filter #'full-stmt-filter)))
      (is (ast-full-stmt (aget :stmt1 pick))))))

(deftest clang-pick-general-same-class-no-matching-test ()
  "Ensure calling pick-general with a same-class filter throws
a no-mutation-targets error when a second statement with the same AST class
is not to be found"
  (with-fixture hello-world-clang-control-picks
    (let ((*bad-asts* (list (make-instance 'clang-ast :class :Nothing))))
      (signals no-mutation-targets
               (pick-general *hello-world* #'stmt-asts
                             :filter #'same-class-filter
                             :second-pool #'bad-stmts)))))

(deftest clang-promote-guarded-throws-error-if-no-targets-test ()
  (with-fixture no-mutation-targets-clang
    (handler-case
        (progn
          (build-op (make-instance 'clang-promote-guarded :object *soft*)
                    *soft*)
          (is nil "build-op should have thrown no-mutation-targets error"))
      (error (e)
        (is (equal (type-of e) 'no-mutation-targets)
            "build-op should have thrown no-mutation-targets error")))))



(deftest pick-cut-decl-throws-error-if-no-targets-test ()
  (with-fixture no-mutation-targets-clang
    (signals no-mutation-targets (pick-cut-decl *soft*))))

(deftest pick-swap-decls-throws-error-if-no-targets-test ()
  (with-fixture no-mutation-targets-clang
    (signals no-mutation-targets (pick-swap-decls *soft*))))

(deftest pick-rename-variable-throws-error-if-no-targets-test ()
  (with-fixture no-mutation-targets-clang
    (signals no-mutation-targets (pick-rename-variable *soft*))))

(deftest (cpp-strings-works :long-running) ()
  ;; On this example, clang generates ASTs that are out of
  ;; order. Check that asts->tree handles this case correctly.
  (with-fixture cpp-strings
    (is *soft*)
    (let ((stmt (stmt-with-text *soft* "x == \"test\"")))
      (is stmt)
      (is (eq :CXXOperatorCallExpr (ast-class stmt)))
      (is (every [{eq :ImplicitCastExpr} #'ast-class]
                 (child-asts stmt))))))

(deftest typedef-workaround ()
  (with-fixture typedef
    (let ((typedef (stmt-with-text *soft* "typedef" :at-start t)))
      (is typedef)
      (is (not (null (child-asts typedef))))
      (is (equal '(:Record)
                 (mapcar #'ast-class
                         (child-asts typedef)))))))

(deftest simple-macro-expansion ()
  (with-fixture simple-macros-clang
    ;; Without the -DDEBUG on the command line we only see two
    ;; instances of the FUNCTION_LIKE_DEBUG macro.
    (is (= 2 (count-if [{eql :MACROEXPANSION} #'ast-class] (asts *soft*))))
    ;; Even in this case we still see the "ifdef DEBUG" lines in the
    ;; source text of the top level compound statement.
    (is (search "#ifdef DEBUG"
                (source-text (find-if [{eql :COMPOUNDSTMT} #'ast-class]
                                      (asts *soft*)))))))

(deftest overlapping-sibling-asts ()
  ;; A combination of macros and case statements produces tricky
  ;; overlapping source ranges. Test that update-asts can handle it
  ;; correctly.
  (with-fixture switch-macros-clang
    (let ((overlapping-children
           (nest (child-asts)
                 (stmt-with-text *soft* "case 'F'" :at-start t))))
      (is (= 2 (length overlapping-children)))
      (is (member :MacroExpansion
                  (mapcar #'ast-class overlapping-children))))))

(deftest var-decl-has-correct-types ()
  (let* ((obj (make-instance 'clang :genome "int x = sizeof(int);"))
         (*soft* obj))
    ;; A var decl should always directly reference the type of its
    ;; declaration. This is tricky due to the de-aggregating of types
    ;; done by asts->tree.

    ;; FIXME: if the RHS were "sizeof(int) + sizeof(char)" the decl
    ;; would reference both types, which is incorrect but probably
    ;; harmless.
    (is (member "int"
                (mapcar [#'type-name {find-type obj}]
                        (ast-types (first (asts obj))))
                :test #'equalp))))

(deftest macro-expansion-has-correct-types ()
  ;; Types inside a macro expansion should be visible. This is trick
  ;; due to the de-aggregating of types done by asts->tree.
  (let* ((obj (make-instance 'clang :genome "#define CHARSIZE (sizeof (char))
int x = CHARSIZE;")))
    (let ((types
           (sort (mapcar [#'type-name {find-type obj}]
                         (get-ast-types obj (first (asts obj))))
                 #'string<)))
      (is (or (equal '("char" "int") types)
              (equal '("char" "int" "unsigned long") types))))))

(deftest able-to-handle-multibyte-characters ()
  (handler-bind (#+sbcl (sb-int:stream-encoding-error
                         (lambda (c)
                           (declare (ignorable c))
                           (invoke-restart 'use-encoding :utf-8))))
    (with-fixture unicode-clang
      (is (stmt-with-text *soft* "int x = 0" :at-start t))
      (is (stmt-with-text *soft* "\"2 bytes: Δ\"" :at-start t))
      (is (stmt-with-text *soft* "int y = 1" :at-start t))
      (is (string= (genome-string *soft*)
                   (file-to-string (unicode-dir "unicode.c")))))))

(deftest type-decl-string-test ()
  (is (equalp "int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type :qual "int"))))
  (is (equalp "int *"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type
                      :qual "int *"
                      :modifiers +pointer+))))
  (is (equalp "const int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type
                      :qual "const int"
                      :modifiers +const+))))
  (is (equalp "volatile int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type
                      :qual "volatile int"
                      :modifiers +volatile+))))
  (is (equalp "restrict int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type
                      :qual "restrict int"
                      :modifiers +restrict+))))
  (is (equalp "auto int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :auto :type)
                    (make-instance 'clang-type :qual "int"))))
  (is (equalp "static int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :static :type)
                    (make-instance 'clang-type :qual "int"))))
  (is (equalp "extern int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :extern :type)
                    (make-instance 'clang-type :qual "int"))))
  (is (equalp "register int"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :register :type)
                    (make-instance 'clang-type :qual "int"))))
  (is (equalp "struct struct_type"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type :qual "struct struct_type"))))
  (is (equalp "union union_type"
              (nest (type-decl-string)
                    (make-instance 'ct+ :storage-class :none :type)
                    (make-instance 'clang-type :qual "union union_type")))))
