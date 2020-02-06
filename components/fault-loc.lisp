;;;; fault-loc.lisp -- fault localization
;;;
;;; Fault localization functions operate on execution traces generated
;;; by the instrument method.
;;;
(defpackage :software-evolution-library/components/fault-loc
  (:nicknames :sel/components/fault-loc :sel/cp/fault-loc)
  (:use :common-lisp
        :alexandria
        :arrow-macros
        :named-readtables
        :curry-compose-reader-macros
        :iterate
        :split-sequence
        :software-evolution-library
        :software-evolution-library/utility
        :software-evolution-library/software/ast
        :software-evolution-library/software/source
        :software-evolution-library/software/parseable
        :software-evolution-library/software/clang
        :software-evolution-library/software/project
        :software-evolution-library/software/clang-project
        :software-evolution-library/components/test-suite)
  (:shadowing-import-from :uiop/utility :nest)
  (:export :*default-fault-loc-weight*
           :*default-fault-loc-cutoff*
           :error-funcs
           :rinard
           :rinard-compare
           :rinard-incremental
           :rinard-write-out
           :rinard-read-in
           :collect-fault-loc-traces
           :decorate-with-annotations
           :perform-fault-loc
           :fault-loc-tarantula
           :fault-loc-only-on-bad-traces))
(in-package :software-evolution-library/components/fault-loc)
(in-readtable :curry-compose-reader-macros)

(defvar *default-fault-loc-weight* 0.05
  "The default weight to give ast nodes that, based on
the chosen strategy, would otherwise have no measured weight.")

(defgeneric collect-fault-loc-traces (bin test-suite read-trace-fn
                                      &optional fl-neg-test)
  (:documentation "Run test cases and collect execution traces.

Returns a list of traces where the notion of \"good\" traces (from
passing tests) \"bad\" traces (from failing tests) are recorded in a
manner that the client can later digest.

BIN is the path to software object which has already been instrumented
and built.  READ-TRACE-FN is a function for reading the traces
generated by that instrumentation. fl-neg-test specifies a list of
tests to be considered the 'failing' tests (indicating a bug,
usually).

No assumptions are made about the format or contents of the traces."))

(defmethod collect-fault-loc-traces (bin test-suite read-trace-fn
                                     &optional fl-neg-test)
  (iter (for test in (test-cases test-suite))
        (note 3 "Begin running test ~a" test)
        (let* ((f (evaluate bin test :output :stream :error :stream))
               ;; Set is-good-trace based on actual outcome, or the
               ;; user-specified "bad test."
               (is-good-trace (cond
                                (fl-neg-test (if (member test fl-neg-test)
                                                 nil
                                                 t))
                                (t (>= f 1.0)))))
          (with accumulated-result = nil)
          (setf accumulated-result
                (funcall read-trace-fn accumulated-result is-good-trace test))
          (finally (return accumulated-result)))))

(defun error-funcs (software bad-traces good-traces)
  "Find statements which call functions which are only called during bad runs.

We call functions which are only called during bad runs \"error
functions.\" Such functions often contain error-handling code which is
not itself faulty, so it's useful to identify their callers instead."
  (labels
      ((stmts-in-file (trace file-id)
         (remove-if-not [{= file-id} {aget :f}] trace))
       (call-sites (obj neg-test-stmts error-funcs)
         (remove-if-not (lambda (x)
                          (remove-if-not
                           (lambda (y)
                             (let ((cur-node (ast-at-index obj x)))
                               (and (eq (ast-class cur-node)
                                        :CallExpr)
                                    (search y (source-text cur-node)))))
                           error-funcs))
                        neg-test-stmts))
       (functions (obj trace)
         (remove-duplicates
          (mapcar [{function-containing-ast obj} {ast-at-index obj}]
                  ;; Not necessary, but this is faster than doing
                  ;; duplicate function-containing-ast lookups.
                  (remove-duplicates trace))))
       (find-error-funcs (obj good-stmts bad-stmts)
         (mapcar #'ast-name
                 (set-difference (functions obj bad-stmts)
                                 (functions obj good-stmts)
                                 :test #'equalp))))

    ;; Find error functions in each file individually, then append them.
    (let ((good-stmts (apply #'append good-traces))
          (bad-stmts (apply #'append bad-traces)))
      (iter
        (for obj in (mapcar #'cdr (evolve-files software)))
        (for i upfrom 0)
        (let ((good (mapcar {aget :c} (stmts-in-file good-stmts i)))
              (bad (mapcar {aget :c} (stmts-in-file bad-stmts i))))
          (appending
           (mapcar (lambda (c) `((:c . ,c) (:f . ,i)))
                   (call-sites obj
                               (remove-duplicates bad)
                               (find-error-funcs obj good bad)))))))))

(defstruct stmt-counts
  "A struct for a single stmt-count entry.
This includes the test id, the number of positive and negative tests
that exercise the statement, and an alist for positions in traces,
which maps (test-casel: position)"
  (id "")
  (positive 0.0)
  (negative 0.0)
  ;; The `stmt-counts' "positions" field gets its own struct for
  ;; printing purposes.
  (positions '()))

(defun add-to-pos (k v sc)
  "DOCFIXME
* K DOCFIXME
* V DOCFIXME
* SC DOCFIXME
"
  ;; acons "k: v" onto positions, double-unwrapping
  (setf (stmt-counts-positions sc)
        (acons k v (stmt-counts-positions sc))))

(defun pp-stmt-counts (sc)
  "DOCFIXME
* SC DOCFIXME
"
  (format nil "~a : [pos: ~a, neg: ~a] -- [~a]"
          (stmt-counts-id sc)
          (stmt-counts-positive sc)
          (stmt-counts-negative sc)
          (pp-positions (stmt-counts-positions sc))))

(defun pp-positions (pos)
  "DOCFIXME
* POS
"
  (when pos
    (let ((pair_lst (loop :for key :in (mapcar 'car pos)
                       :for value :in (mapcar 'cdr pos)
                       :collecting (format nil "~a:~a" key value))))
      (format nil "~{~a~^,~}" pair_lst))))

(defun rinard-write-out (path data)
  "Write out fault localization to speed up subsequent trials.

* PATH full system path to write to.
* DATA fault loc data, as returned by `rinard'.
"
  (with-open-file (stream path :direction :output
                          :if-exists :supersede :if-does-not-exist :create)
    (format stream "~a~%" (hash-table-alist data))))

(defun rinard-read-in (path)
  "Read in previously-written fault localization info.
* PATH full system path to read in from, previously
       written out by `rinard-write-out'.
"
  (with-open-file (stream path)
    (let ((alst (loop :for line = (read stream nil :done)
                   :while (not (eq line :done))
                   :collect line)))
      (alist-hash-table alst))))

(defun rinard-compare (a b)
  "Return non-nil if A is more suspicious than B."
  ;; A is more suspicious than B if any of the following are true:
  (cond
    ((> (stmt-counts-negative a) (stmt-counts-negative b)) t)
    ((< (stmt-counts-negative a) (stmt-counts-negative b)) nil)
    ;; Negative count is equal.
    ((< (stmt-counts-positive a) (stmt-counts-positive b)) t)
    ((> (stmt-counts-positive a) (stmt-counts-positive b)) nil)
    ;; Both counts are equal: which is executed later in more tests?
    (t (let* ((pos_a (stmt-counts-positions a))
              (pos_b (stmt-counts-positions b))
              ;; Pairs of positions for traces both a and b appear in.
              (shared_traces (remove nil
                               (loop :for key :in (mapcar 'car pos_a)
                                  :for val_a :in (mapcar 'cdr pos_a)
                                  :collect (let ((pair_b (assoc key pos_b)))
                                             (if pair_b
                                                 (cons val_a (cdr pair_b))
                                                 nil))))))
         (> (count t (mapcar (lambda (pair)
                               (> (or (car pair) -1) (or (cdr pair) -1)))
                             shared_traces))
            (/ (length shared_traces) 2))))))

(defun rinard (count obj stmt-counts)
  "Spectrum-based fault localization from SPR and Prophet.
* COUNT size of prioritized list to return
* OBJ software object under test
* STMT-COUNTS aggregated trace results, collected from `rinard-incremental'
"
  (declare (ignorable obj))
  (note 2 "Start rinard")
  (let ((stmt-counts-vals (loop for value being the hash-values of stmt-counts
                             collecting value )))
    (let ((sorted (sort stmt-counts-vals #'rinard-compare)))
      ;; Comment in to print out the actual fault loc list with counts.
      ;; (print-rinard sorted)
      (mapcar #'stmt-counts-id (take count sorted)))))

(defun print-rinard (sorted)
  "DOCFIXME
* SORTED DOCFIXME
"
  (with-open-file (stream (pathname "/tmp/GP_fault_loc_sorted")
                          :direction :output :if-exists :supersede)
    (loop :for stmt :in sorted
       :do (format stream "~a~%" (pp-stmt-counts stmt)))))

(defun rinard-incremental (trace-stream stmt-counts is-good-trace cur_test)
  "Process a single trace's output, return the aggregated results.
* TRACE-STREAM an open file representing the trace result, generally
        with statments of the form ((F . X) (C . Y)) where X is the
        file id and Y is the statement id
* STMT-COUNTS aggregated results, returned from this function
* IS-GOOD-TRACE test outcome was positive/negative
* CUR_TEST unique test identifier
"
  ;; find position of last occurrence of stmt in trace
  (note 3 "Start rinard-incremental")
  (unless stmt-counts
    (setf stmt-counts (make-hash-table)))

  (flet ((increment-counts (stmt-count is-good-trace)
           (setf (stmt-counts-positive stmt-count)
                 (+ (stmt-counts-positive stmt-count)
                    (if is-good-trace 1 0)))
           (setf (stmt-counts-negative stmt-count)
                 (+ (stmt-counts-negative stmt-count)
                    (if is-good-trace 0 1))))
         ;; we need actual stmt values, rather than strings for later comparisons
         (fix-string-fields (trace-results)
           (let ((rehash (make-hash-table :test #'equal)))
             (loop for key being the hash-keys of trace-results
                using (hash-value value)
                do (let ((k (if (stringp key)
				(read-from-string key)
				key)))
                     (setf (stmt-counts-id value) (stmt-counts-id value))
                     (setf (gethash k rehash) value)))
             rehash)))
    ;; use new-counts to trace stmts occurring in current trace
    (let ((new-counts (make-hash-table :test #'equal)))
      (iter (for stmt = (read-line trace-stream nil :done))
        (for i upfrom 0)
        (while (not (eq stmt :done)))
	  ;; convert to sexp
	  (setf stmt (read-from-string stmt))
          ;; we'll never store 'nil' as a key, so just inspecting returned val is fine
          (let ((stmt-count (gethash stmt new-counts)))
            (if stmt-count
                ;; stmt occurred earlier in this trace: update last position
                (unless is-good-trace
                  (rplacd (assoc cur_test (stmt-counts-positions stmt-count)) i))
                ;; stmt has not already occurred in this trace
                (let ((stmt-count (gethash stmt stmt-counts)))
                  (if stmt-count
                      ;; stmt occurred in a prior trace
                      (progn
                        ;; add to stmts seen in trace, add position, increment
                        ;; counts
                        (setf (gethash (stmt-counts-id stmt-count) new-counts) stmt-count)
                        (unless is-good-trace
                          (setf (stmt-counts-positions stmt-count) (acons cur_test i (stmt-counts-positions stmt-count))))
                        (increment-counts stmt-count is-good-trace))
                      ;; new stmt not yet seen in any trace
                      (let ((new-count (make-stmt-counts
                                        :id stmt
                                        :positive (if is-good-trace 1.0 0.0)
                                        :negative (if is-good-trace 0.0 1.0)
                                        :positions  (if is-good-trace
                                                        '()
                                                        (list (cons cur_test i))))))
                        (setf (gethash (stmt-counts-id new-count) new-counts) new-count)
                        (setf (gethash (stmt-counts-id new-count) stmt-counts) new-count))))))))
  (note 3 "End rinard-incremental")

  ;; debug -- use to compare fault loc info to other techniques
  ;; (let ((sorted_keys (sort (loop for key being the hash-keys of stmt-counts
  ;;                             collecting key)
  ;;                          #'string-lessp)))
  ;;   (loop for x in sorted_keys
  ;;      do
  ;;        (multiple-value-bind (val found) (gethash x stmt-counts)
  ;;          (format t "~S : ~S~%" x (pp-stmt-counts val)))))

  (fix-string-fields stmt-counts)))

(defgeneric annotate-line-nums (object ast)
  (:documentation
   "Add line numbers to annotations, generally for debugging purposes")
  (:method ((obj clang) (ast clang-ast))
    (let ((loc (clang-range-begin (ast-range ast))))
      (unless (numberp loc)
        (let* ((line (clang-loc-line loc)))
          (setf (ast-attr ast :annotations) (cons :line line)))))))

(defgeneric decorate-with-annotations (software file)
  (:documentation "Decorate SOFTWARE with annotations from FILE.")
  (:method ((obj clang-project) (ast-annotations pathname))
    (mapcar (lambda (efile) (decorate-with-annotations (cdr efile) ast-annotations))
            (evolve-files obj)))
  (:method ((obj clang) (ast-annotations pathname))
    (flet ((ann-file (annotation) (first annotation))
           (ann-line (annotation) (second annotation)))
      (let ((file-annotations (nest
                               (remove-if-not ; Filter to just this file.
                                [{search _ (original-file obj)} #'ann-file])
                               (mapcar #'read-from-string)
                               (split-sequence #\Newline
                                               (file-to-string ast-annotations)
                                               :remove-empty-subseqs t))))
        ;; NOTE: Unnecessary quadratic, could be made faster by first
        ;;       sorting the annotations and statements by line
        ;;       number.  May never matter.
        (dolist (ast (stmt-asts obj))
          (dolist (annotation file-annotations)
            (when (within-ast-range (ast-range ast) (ann-line annotation))
              (push annotation (ast-attr ast :annotations)))))))))

(defun good-trace-count (stmt)
  "Count the :GOOD annotations for STMT."
  (length (remove-if-not {eql :good} (flatten (ast-attr stmt :annotations)))))

(defun bad-trace-count (stmt)
  "Count the :BAD annotations for STMT."
  (length (remove-if-not {eql :bad} (flatten (ast-attr stmt :annotations)))))

(defvar *default-fault-loc-cutoff* 0.5
  "Chance of picking things that didn't appear in the trace.
Default is an \"even chance,\" should adjust based on needs and
strategy.")

(defun filter-fault-loc (pool)
  "AST nodes in POOL may be annotated with 'fl-weight' tags, indicating how
suspect individual nodes are from 0 (not suspect) to 1 (fully suspect).
If these tags are present, randomly generate a cutoff and filter out
nodes below that cutoff.  This can result in an empty set -- in this case,
return the original pool."
  (unless (member :fl-weight (flatten (mapcar {ast-attr _ :annotations} pool)))
    (return-from filter-fault-loc pool)) ; If no fl-weights, return pool as-is.
  (labels ((fl-weight (ast)
             (let ((elt (find :fl-weight (ast-attr ast :annotations)
                              :key #'car)))
               (if elt (cdr elt) *default-fault-loc-cutoff*))))
    (let ((filtered-lst (remove-if-not [{> _ (random 1.0)} #'fl-weight] pool)))
      (if filtered-lst ; If non-empty:
          filtered-lst ;  return it,
          pool)))) ;  otherwise return the original set.

(defmethod mutation-targets :around ((obj clang)
                                     &key (filter nil) (stmt-pool #'stmt-asts))
  "Wrap mutation targets to perform optional fault localization.

* OBJ software object to query for mutation targets
* FILTER filter AST from consideration when this function returns nil
* STMT-POOL method on OBJ returning a list of ASTs"
  (call-next-method obj :filter filter
                    :stmt-pool [#'filter-fault-loc {funcall stmt-pool}]))

(defun add-default-weights (ast)
  "Add default weight for those AST nodes that currently lack one."
  (when (not (member :fl-weight (flatten (ast-attr ast :annotations))))
    (push (list (cons :fl-weight *default-fault-loc-weight*))
          (ast-attr ast :annotations))))

;;;; Annotations are deployed on AST objects, thus anything that
;;;; implements "ast-root" and "stmt-asts" can use FL (this should be
;;;; anything "clang" or below).  This function serves to as an
;;;; interface to hide the chosen fault loc strategy
(defmethod perform-fault-loc ((obj clang))
  (fault-loc-tarantula obj)
  (mapc #'add-default-weights (stmt-asts obj)))

(defmethod perform-fault-loc ((obj project))
  (mapc #'fault-loc-tarantula (mapcar #'cdr (evolve-files obj)))
  (mapc #'add-default-weights
        (flatten (mapcar [#'stmt-asts #'cdr] (evolve-files obj)))))

(defmethod fault-loc-tarantula ((obj clang))
  "Annotate ast nodes in obj with :fl-weight tag and a `score`
indicating how suspect a node is, using the popular spectrum-based
Tarantula technique. Note: here we use the inverse, scoring 'suspect'
statements high rather than low."
  (mapcar (lambda (stmt)
            (let* ((bad (bad-trace-count stmt))
                   (good (good-trace-count stmt)))
              (when (or (> bad 0) (> good 0)) ; Any trace info.
                (let ((score (/ (float (bad-trace-count stmt))
                                (float (+ (bad-trace-count stmt)
                                          (good-trace-count stmt))))))
                  (push (list (cons :fl-weight score))
                        (ast-attr stmt :annotations))
                  (cons stmt score)))))
          (stmt-asts obj)))

(defmethod fault-loc-only-on-bad-traces ((obj clang))
  "Annotate ast nodes in obj with :fl-weight tag and a `score` indicating
how suspect a node is, targeting nodes that appear only on failing traces."
  (mapcar (lambda (stmt)
            (let ((score (if (and (> (bad-trace-count stmt) 0)
                                  (= 0 (good-trace-count stmt)))
                             1.0
                             0.1)))
              (setf (ast-attr stmt :annotations)
                    (append (list (cons :fl-weight score))
                            (ast-attr stmt :annotations)))
              (cons stmt score)))
          (stmt-asts obj)))
