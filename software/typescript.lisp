(defpackage :software-evolution-library/software/typescript
  (:nicknames :sel/software/typescript :sel/sw/typescript)
  (:use :gt/full
        :software-evolution-library
        :software-evolution-library/software/tree-sitter
        :software-evolution-library/software/template))

(in-package :software-evolution-library/software/tree-sitter)
(in-readtable :curry-compose-reader-macros)

;;;===================================================
;;; Generate the language definitions
;;;===================================================
(create-tree-sitter-language "typescript/tsx")
(create-tree-sitter-language "typescript/typescript")
;;;===================================================

(defmethod from-file ((class (eql 'typescript)) file)
  (from-file 'typescript-ts file))

(defmethod from-file ((software typescript) file)
  (from-file (change-class software 'typescript-ts) file))

(defmethod from-string ((class (eql 'typescript)) string)
  (from-string 'typescript-ts string))

(defmethod from-string ((software typescript) string)
  (from-string (change-class software 'typescript-ts) string))

(defmacro with-tsx-methods ((&key) &body body)
  "Given methods specialized on `typescript-ts', also generate methods
specialized on `typescript-tsx'."
  (assert (every (eqls 'defmethod) (mapcar #'car body)))
  (let ((package (find-package :sel/sw/ts)))
    (flet ((retarget (form from to)
             (leaf-map (lambda (leaf)
                         (if (and (symbolp leaf)
                                  (not (keywordp leaf))
                                  (string^= from leaf))
                             (intern (string+ to
                                              (drop-prefix
                                               (string from)
                                               (string leaf)))
                                     package)
                             leaf))
                       form)))
      `(progn
         ,@(iter (for form in body)
                 (collect form)
                 (collect (retarget form
                                    'typescript-ts
                                    'typescript-tsx)))))))

#+:TREE-SITTER-TYPESCRIPT/TYPESCRIPT
(with-tsx-methods ()

  ;; NB What should `function-parameters' return in the presence of
  ;; destructuring? Given a parameter list like `({a, b, c}, {x, y z})'
  ;; are there two parameters or six? Currently our answer is two, not
  ;; just because it's simpler, but because it's not just for analysis;
  ;; it's also for programs that wants to generate test inputs. That
  ;; said the six-parameter case might eventually deserve another
  ;; function.

  (defmethod parameter-type ((ast typescript-ts-required-parameter))
    (find-if (of-type 'typescript-ts-type-annotation)
             (children ast)))

  (defmethod function-name ((ast typescript-ts-function-declaration))
    (source-text (typescript-ts-name ast)))

  (defmethod end-of-parameter-list ((software typescript-ts)
                                    (fn typescript-ts-function-declaration))
    (ast-end software (typescript-ts-parameters fn)))

  (defmethod function-parameters ((ast typescript-ts-function-declaration))
    (children (typescript-ts-parameters ast)))

  (defmethod end-of-parameter-list ((software typescript-ts)
                                    (fn typescript-ts-function-declaration))
    (ast-end software (typescript-ts-parameters fn)))

  (defmethod function-parameters ((ast typescript-ts-function))
    (children (typescript-ts-parameters ast)))

  (defmethod end-of-parameter-list ((software typescript-ts)
                                    (fn typescript-ts-arrow-function))
    (ast-end software
             (or (typescript-ts-parameters fn)
                 (typescript-ts-parameter fn))))

  (defmethod function-parameters ((fn typescript-ts-arrow-function))
    (econd-let p
               ((typescript-ts-parameters fn)
                (children p))
               ((typescript-ts-parameter fn)
                (list p)))))
