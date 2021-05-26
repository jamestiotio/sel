(defpackage :software-evolution-library/software/cpp
  (:nicknames :sel/software/cpp :sel/sw/cpp)
  (:use :gt/full
   :cl-json
   :software-evolution-library
   :software-evolution-library/software/tree-sitter
   :software-evolution-library/software/c-cpp))

(in-package :software-evolution-library/software/tree-sitter)
(in-readtable :curry-compose-reader-macros)

;;;===================================================
;;; Generate the language definitions
;;;===================================================
;;; !! Language generated in c-cpp !!
;;;===================================================

(defmethod initialize-instance :after ((cpp cpp)
                                       &key &allow-other-keys)
  "If no compiler was specified, default to cc."
  (unless (compiler cpp)
    (setf (compiler cpp) "c++")))

(defmethod transform-parse-tree
    ((language (eql ':cpp)) (class (eql 'cpp-preproc-ifdef)) parse-tree)
  "Transform PARSE-TREE such that all modifiers are stored in the :modifiers
field."
  (append
   (butlast parse-tree)
   (list
    (mapcar
     (lambda (child-tree)
       (cond
         ((member (car child-tree) '(:|#IFDEF| :|#IFNDEF|))
          (cons (list :operation (car child-tree)) (cdr child-tree)))
         (t child-tree)))
     (lastcar parse-tree)))))

(defun add-operator-to-binary-operation (parse-tree)
  "Adds modifies the operator in a binary operation such that it is
stored in :operator."
  (append
   (butlast parse-tree)
   (list
    (mapcar
     (lambda (child-tree &aux (car (car child-tree)))
       (cond
         ((consp car) child-tree)
         ((member car '(:error :comment)) child-tree)
         (t (cons (list :operator (car child-tree))
                  (cdr child-tree)))))
     (lastcar parse-tree)))))

(defmethod transform-parse-tree
    ((language (eql ':cpp)) (class (eql 'cpp-assignment-expression)) parse-tree)
  "Transform PARSE-TREE such that the operator is stored in the :operator field."
  (add-operator-to-binary-operation parse-tree))

(defmethod transform-parse-tree
    ((language (eql ':cpp)) (class (eql 'cpp-field-expression)) parse-tree)
  "Transform PARSE-TREE such that the operator is stored in the :operator field."
  (add-operator-to-binary-operation parse-tree))

(defmethod ext :around ((obj cpp)) (or (call-next-method) "cpp"))

(defmethod function-body ((ast cpp-function-definition)) (cpp-body ast))

(defmethod cpp-declarator ((ast cpp-reference-declarator))
  (if (single (children ast))
      (cpp-declarator (first (children ast)))
      (call-next-method)))

(defmethod c/cpp-declarator ((ast cpp-reference-declarator))
  (cpp-declarator ast))

(defmethod definition-name ((ast cpp-class-specifier))
  (source-text (cpp-name ast)))
