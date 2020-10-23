;;;; tree-sitter.lisp --- software representations with a tree-sitter backend.
(uiop:define-package :software-evolution-library/software/tree-sitter
  (:nicknames :sel/software/tree-sitter :sel/sw/tree-sitter
              :sel/software/ts :sel/sw/ts)
  (:use :gt/full
        :babel
        :cl-json
        :software-evolution-library
        :software-evolution-library/utility/json
        :software-evolution-library/software/parseable
        :software-evolution-library/software/non-homologous-parseable
        :software-evolution-library/components/file
        :software-evolution-library/components/formatting)
  (:import-from :cffi :translate-camelcase-name)
  (:import-from :cl-tree-sitter :register-language)
  (:shadowing-import-from :cl-tree-sitter :parse-string)
  (:export :register-tree-sitter-language
           :tree-sitter-ast
           :tree-sitter
           :define-tree-sitter-classes
           :create-convert-methods
           :update-child-order
           :inconsistent-production-p))
(in-package :software-evolution-library/software/tree-sitter)
(in-readtable :curry-compose-reader-macros)

(define-software tree-sitter (non-homologous-parseable) ()
  (:documentation "tree-sitter software representation."))


;;; Shared object set-up
(eval-always
  (defvar *superclass->language* (make-hash-table)))

(defmacro register-tree-sitter-language (lib-name language ast-superclass)
  "Setup LANGUAGE to map to AST-SUPERCLASS and use LIB-NAME for parsing."
  `(eval-always
     (setf (gethash ,ast-superclass *superclass->language*) ,language)
     (register-language ,language ,lib-name)))


;;; Defining tree-sitter classes
(eval-always
  (defclass tree-sitter-ast (non-homologous-ast)
    ()
    (:documentation "AST for input from tree-sitter."))

  (defun convert-name (name-string)
    (camel-case-to-lisp (substitute #\- #\_  name-string)))

  (defgeneric inconsistent-production-p (language production-name)
    (:documentation "Return T if PRODUCTION-NAME in LANGUAGE has an
inconsistent graph when a topological sort of its field dependencies
is attempted.")
    (:method (language production-name)
      nil))

  ;; TODO: makes more sense to pass in the grammar json and only read in the
  ;;       file once in the macro.
  (defun slot-order (name grammar-filepath ast-superclass
                     &aux dependencies fields)
    "Return the slot order of the fields in the production specified
by NAME. If NIL is returned, there are either no fields or the order
of fields needs to be determined at parse-time."
    (labels ((add-dependency (preceding-fields field)
               "Add a dependency for each on each item
              in PRECEDING-FIELDS for field."
               ;; NOTE: this can potentially add duplicate dependencies
               ;;       though this likely isn't much of a problem.
               (mapc
                (lambda (preceding-field)
                  (unless (equal preceding-field field)
                    (push (list preceding-field field) dependencies)))
                preceding-fields))
             (add-field (name)
               "Add NAME to the list of used fields."
               ;; NOTE: avoid adding the same field more than once.
               ;;       This can occur with 'CHOICE' rules.
               (setf fields (union fields (list name) :test #'equal)))
             (handle-choice (rule &optional preceding-fields)
               "Handle RULE as a 'CHOICE' rule."
               (remove-duplicates
                (iter
                  (for member in (aget :members rule))
                  (appending (handle-rule member preceding-fields)))
                :test #'equal))
             (handle-seq (rule &optional preceding-fields)
               "Handle RULE as a 'SEQ' rule."
               (iter
                 (for member in (aget :members rule))
                 (for preceding
                      initially preceding-fields
                      then (or (handle-rule member preceding)
                               preceding))
                 (finally (return preceding))))
             (handle-repeat (rule &optional preceding-fields)
               "Handle RULE as a 'REPEAT' rule."
               ;; NOTE: perform twice to loop the ending field of the repeat
               ;;       back to the front of the repeat. This will create
               ;;       an inconsistency if one exists. Also note that
               ;;       a dependency of a field on itself is ignored.
               (iter
                 (repeat 2)
                 (for preceding
                      initially preceding-fields
                      then (or (handle-rule (aget :content rule) preceding)
                               preceding))))
             (handle-field (rule &optional preceding-fields
                            &aux (name (aget :name rule)))
               "Handle RULE as a 'FIELD' rule and add a dependency from
              the field to PRECEDING-FIELDS if it exists."
               (add-field name)
               (add-dependency preceding-fields name)
               (list name))
             (handle-rule (rule &optional preceding-fields)
               "Handles dispatching RULE to its relevant rule handler."
               ;; NOTE: this will throw an error if the json schema for
               ;;       the grammar.json files has changed.
               (string-ecase (aget :type rule)
                 (("ALIAS" "BLANK" "IMMEDIATE_TOKEN" "TOKEN" "PATTERN" "STRING"
                           "SYMBOL"))
                 ("CHOICE" (handle-choice rule preceding-fields))
                 ("FIELD" (handle-field rule preceding-fields))
                 (("PREC" "PREC_DYNAMIC" "PREC_LEFT" "PREC_RIGHT")
                  ;; pass-through
                  (handle-rule (aget :content rule) preceding-fields))
                 (("REPEAT" "REPEAT1")
                  (handle-repeat rule preceding-fields))
                 ("SEQ" (handle-seq rule preceding-fields))))
             (get-rules (&aux (*json-identifier-name-to-lisp* #'convert-name))
               "Get the rules associated with the grammar."
               (aget
                :rules
                (decode-json-from-string
                 (file-to-string grammar-filepath)))))
      ;; NOTE: tree-sitter/cli/src/generate/grammar-schema.json
      ;;       The grammar schema contains information on the
      ;;       possible rule types.
      (let* ((name-keyword (make-keyword (convert-name name)))
             (name-rule (aget name-keyword (get-rules))))
        (cond
          ((not name-rule))
          ((inconsistent-production-p
            (gethash ast-superclass *superclass->language*)
            name-keyword)
           (handle-rule name-rule)
           ;; NOTE: the order doesn't matter as a :child-order
           ;;       annotation will be used instead of it.
           ;;       This is only provided for #'sorted-children
           ;;       to use.
           (mapcar #'make-keyword (mapcar #'convert-name fields)))
          (t
           (handle-rule name-rule)
           (mapcar
            #'make-keyword
            (mapcar
             #'convert-name
             (sort fields (toposort dependencies :test #'equal))))))))))

(defmacro define-tree-sitter-classes
    (() node-types-file grammar-file name-prefix ast-superclass
     &aux (subtype->supertypes (make-hash-table :test #'equal)))
  ;; TODO: figure out what needs exported, where, and how to do it without
  ;;       creating several symbol collisions.
  ;; TODO: possibly only turn _'s into -'s if the node is named and has fields
  ;;       or children. This will keep things--like __attribute__, __fastcall,
  ;;       __unaligned, etc.--in their intended, keyword format.
  (labels ((make-class-name (name-string)
             "Create a class name based on NAME-STRING."
             ;; NOTE: this has the potential of name clashes
             ;;       though it's probably unlikely.
             (symbolicate
              name-prefix
              "-"
              (convert-name name-string)))
           (get-supertypes-for-type (type)
             "Retrieve the supertypes of TYPE."
             (gethash type subtype->supertypes))
           (add-supertype-to-subtypes (supertype subtypes)
             "Add SUPERTYPE to the list of superclasses for
              each type in SUBTYPES."
             (mapc
              (lambda (subtype &aux (name (aget :type subtype)))
                (push supertype (gethash name subtype->supertypes)))
              subtypes))
           (create-slot (field &aux (name-key (car field)))
             "Create a slot based on FIELD."
             `(,(symbolicate name-key)
               ;; TODO: add accessor
               :initarg ,name-key
               :initform nil))
           (create-slots (fields children)
             "Create the slots for a new class based on FIELDS and CHILDREN.
              Currently, types aren't supported, but there is enough information
              to limit slots to certain types."
             ;; TODO: there is a potential for name overlaps when generating
             ;;       these classes.
             (if children
                 (cons
                  (create-slot children)
                  (mapcar #'create-slot fields))
                 (mapcar #'create-slot fields)))
           (create-supertype-class (type subtypes)
             "Create a new class for subtypes to inherit from."
             (add-supertype-to-subtypes type subtypes)
             `(defclass ,(make-class-name type)
                  (,@(or
                      (mapcar #'make-class-name (get-supertypes-for-type type))
                      `(,ast-superclass)))
                ()
                (:documentation ,(format nil "Generated for ~a." type))))
           (create-type-class (type fields children)
             "Create a new class for TYPE using FIELDS and CHILDREN for slots."
             (let ((child-slot-order
                     (when fields
                       (mapcar
                        (lambda (slot-keyword)
                          (cons
                           (symbolicate slot-keyword)
                           (if (aget :multiple (aget slot-keyword fields)) 0 1)))
                        (slot-order type grammar-file ast-superclass)))))
               `(defclass ,(make-class-name type)
                    (,@(or
                        (mapcar #'make-class-name (get-supertypes-for-type type))
                        `(,ast-superclass)))
                  (,@(create-slots fields children)
                   (child-slots
                    :initform
                    ;; TODO: push on children if it exists.
                    ',(if children
                          (append child-slot-order '((children . 0)))
                          child-slot-order)
                    :allocation :class))
                  ;; NOTE: this is primarily for determing which rule this
                  ;;       was generated for.
                  (:documentation ,(format nil "Generated for ~a." type)))))
           (create-node-class
               (node-type &aux (type (aget :type node-type))
                            (subtypes (aget :subtypes node-type)))
             "Create a class for  NODE-TYPE."
             ;; TODO: figure out how terminals should be handled--does it
             ;;       make sense to have classes for everything, e.g.,
             ;;       c-#endif and c-++?
             (if subtypes
                 (create-supertype-class
                  type
                  subtypes)
                 (create-type-class
                  type
                  (aget :fields node-type)
                  (assoc :children node-type)))))
    (let* ((*json-identifier-name-to-lisp* #'convert-name)
           (file-string (file-to-string node-types-file))
           (node-types (decode-json-from-string file-string)))
      `(progn
         (eval-always
           ,@(mapcar #'create-node-class node-types)

           ;; NOTE: the following are to handle results returned from
           ;;       cl-tree-sitter.
           ;;
           ;; TODO: this may need to be modified at the cl-tree-sitter level
           ;;       to account for grammars that have an error and/or comment
           ;;       production that could cause a name clash.
           (defclass ,(make-class-name "comment") (,ast-superclass)
             ()
             (:documentation "Generated for parsed comments."))

           (defclass ,(make-class-name "error") (,ast-superclass)
             ((children :initarg :children :initform nil)
              (child-slots :initform '((children . 0))
                           :allocation :class))
             (:documentation "Generated for parsing errors.")))

         (defmethod convert
             ((to-type (eql ',ast-superclass)) (spec ,ast-superclass)
              &key &allow-other-keys)
           spec)

         (defmethod convert ((to-type (eql ',ast-superclass)) (spec list)
                             &key &allow-other-keys)
           (convert 'tree-sitter-ast spec :superclass to-type))

         (defmethod convert ((to-type (eql ',ast-superclass)) (string string)
                             &key &allow-other-keys)
           (convert 'tree-sitter-ast string :superclass to-type))))))


;;; tree-sitter parsing
(defgeneric update-child-order (language ast)
  (:documentation "Return a child ordering if AST requires an ordering
to be created based on what has been read in.")
  (:method (language (ast tree-sitter-ast)) nil))


;;; NOTE: this is specific for cl-tree-sitter.
(defun convert-initializer
    (spec prefix superclass
     &aux (instance (make-instance
                     (symbol-cat-in-package (symbol-package superclass)
                                            prefix
                                            (let ((type (car spec)))
                                              ;; The form can either be
                                              ;; - :type
                                              ;; - (:slot-name :type)
                                              (if (listp type)
                                                  (cadr type)
                                                  type)))
                     :annotations
                     `((:range-start ,(caadr spec))
                       (:range-end . ,(cdadr spec))))))
  "Initialize an instance of SUPERCLASS with SPEC."
  (labels ((get-converted-fields ()
             "Get the value of each field after it's been converted
              into an AST."
             (iter
               (for field in (caddr spec))
               (for converted-field = (convert superclass field))
               (for slot-info = (car field))
               ;; cl-tree-sitter appears to put the
               ;; slot name first unless the list goes
               ;; into the children slot.
               (if (listp slot-info)
                   (collect (list (car slot-info)
                                  converted-field)
                     into fields)
                   (collect converted-field into children))
               (finally
                (return
                  (if children
                      (push `(:children ,children) fields)
                      fields)))))
           (merge-same-fields (field-list)
             "Merge all fields that belong to the same slot.
              This is used for setting slots with an arity of 0."
             (mapcar
              (lambda (grouping)
                (apply #'append
                       (list (caar grouping))
                       (mapcar #'cdr grouping)))
              (assort field-list :key #'car)))
           (set-slot-values (slot-values)
             "Set the slots in instance to correspond to SLOT-VALUES."
             (mapc
              (lambda (list)
                (setf (slot-value instance (symbolicate (car list)))
                      (if (null (cddr list))
                          (cadr list)
                          (cdr list))))
              slot-values))
           (update-slots-based-on-arity ()
             "Update any slot in instance that needs to be converted to a list
              to match its arity. This is primarily for #'sorted-children."
             (mapc
              (lambda (slot-arity &aux (slot (symbolicate (car slot-arity))))
                (symbol-macrolet ((slot-value (slot-value instance slot)))
                  (unless (listp slot-value)
                    (setf slot-value (list slot-value)))))
              (remove-if-not
               {eql 0}
               (or (ast-annotation instance :child-order)
                   (slot-value instance 'child-slots))
               :key #'cdr))))
    (set-slot-values (merge-same-fields (get-converted-fields)))
    (update-child-order (gethash superclass *superclass->language*) instance)
    (update-slots-based-on-arity)
    instance))

(defun range< (range1 range2)
  ;; TODO: refactor this
  (let* ((range1-col (car range1))
         (range1-row (cadr range1))
         (range2-col (car range2))
         (range2-row (cadr range2)))
    (cond
      ((= range1-row range2-row)
       (< range1-col range2-col))
      ((< range1-row range2-row)
       t))))

(defun range-subseq (lines range1 range2)
  ;; TODO: refactor this
  (let* ((range1-col (car range1))
         (range1-row (cadr range1))
         (range2-col (car range2))
         (range2-row (cadr range2)))
    (cond
      ((= range1-row range2-row)
       (subseq (aref lines range1-row) range1-col range2-col))
      ((< range1-row range2-row)
       (concatenate
        'string
        (subseq (aref lines range1-row) range1-col)
        (subseq (aref lines range2-row) 0 range2-col)))
      (t ""))))

(defun get-language-from-superclass (superclass)
  "Get the tree-sitter  language associated with SUPERCLASS."
  (or (gethash superclass *superclass->language*)
      (error "No tree-sitter language known for ~a." superclass)))

(defmethod convert ((to-type (eql 'tree-sitter-ast)) (spec tree-sitter-ast)
                    &key &allow-other-keys)
  "Pass thru an existing tree-sitter AST. This useful in manual AST creation."
  spec)

(defmethod convert ((to-type (eql 'tree-sitter-ast)) (spec list)
                    &key superclass &allow-other-keys)
  "Create a c-tree-sitter AST from the SPEC (specification) list."
  (convert-initializer
   spec (get-language-from-superclass superclass) superclass))

(defmethod convert ((to-type (eql 'tree-sitter-ast)) (string string)
                    &key superclass &allow-other-keys
                    &aux (lines (apply
                                 #'vector
                                 ;; TODO: there's probably a split of some sort
                                 ;;       that leaves the newlines in somewhere.
                                 (iter
                                   (iter:with reverse-lines
                                              = (reverse (lines string)))
                                   (iter:with last = (car reverse-lines))
                                   (for line in (cdr reverse-lines))
                                   (collect (concatenate
                                             'string line (format nil "~%"))
                                     into lines)
                                   (finally
                                    (return (reverse (cons last lines))))))))
  (labels
      ((safe-subseq (start end)
         "Return STRING in the range [START, END) or an empty string if
         the offsets are invalid."
         (if (range< start end)
             (range-subseq lines start end)
             ""))
       (start (ast)
         "Return the start offset into STRING from the AST representation."
         (car (ast-annotation ast :range-start)))
       (end (ast)
         "Return the end offset into STRING from the AST representation."
         (car (ast-annotation ast :range-end)))
       (normalized-children (ast)
         "Return the sorted, non-nil children of AST after destructively
         modifying AST to add a :child-order annotation to those AST types
         whose children are not in a textual order by default."
         (sorted-children ast))
       (ranges (children from to)
         "Return the offsets of the source text ranges between CHILDREN."
         (iter
           (for child in children)
           (for prev previous child)
           (if prev
               (collect (cons (end prev) (start child)) into ranges)
               (collect (cons from (start child)) into ranges))
           (finally (return (append ranges
                                    (list (cons (end child) to)))))))
       (w/interleaved-text (ast from to
                            &aux (children (normalized-children ast)))
         "Destructively modify AST to populate the INTERLEAVED-TEXT
         field with the source text to be interleaved between the
         children of AST."
         (if children
             (progn
               (setf (slot-value ast 'interleaved-text)
                     (mapcar (lambda (range)
                               (destructuring-bind (from . to) range
                                 (safe-subseq from to)))
                             (ranges children from to)))
               (mapc (lambda (child)
                       (w/interleaved-text child (start child) (end child)))
                     children))
             (setf (slot-value ast 'interleaved-text)
                   (list (safe-subseq (start ast) (end ast)))))
         (setf (slot-value ast 'annotations)
               (adrop '(:range-start :range-end) (slot-value ast 'annotations)))
         ast))
    ;; TODO: need to actually fix-newlines. It's probably just a copy-paste
    ;;       javascript.lisp. It may require some extra work on a per-language
    ;;       basis.
    (nest ;(fix-newlines)
     (w/interleaved-text
      (convert to-type
               (parse-string (get-language-from-superclass superclass) string)
               :superclass superclass)
      '(0 0) (list (length (last-elt lines))
                   (1- (length lines)))))))
