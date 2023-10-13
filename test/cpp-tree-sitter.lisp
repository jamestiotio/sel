;;;; cpp-tree-sitter.lisp --- C tree-sitter representation.
(defpackage :software-evolution-library/test/cpp-tree-sitter
  (:nicknames :sel/test/cpp-tree-sitter :sel/test/cpp-ts)
  (:use
    :gt/full
    :software-evolution-library/test/util
    :stefil+
    :functional-trees/attrs
    :software-evolution-library
    :software-evolution-library/software/parseable
    :software-evolution-library/software/tree-sitter
    :software-evolution-library/software/cpp
    :software-evolution-library/software/cpp-project
    :software-evolution-library/test/util-clang
    :software-evolution-library/components/file
    :software-evolution-library/components/formatting
    :software-evolution-library/utility/include)
  (:import-from :software-evolution-library/software/tree-sitter
                :inner-declarations
                :outer-declarations
                :contextualize-ast
                :canonicalize-type
                :canonical-type=
                :strip-template-arguments)
  (:import-from :software-evolution-library/software/tree-sitter
                :explicit-namespace-qualifiers
                :qualified-name-variants)
  (:local-nicknames (:project :software-evolution-library/software/project)
                    (:dir :software-evolution-library/software/directory))
  (:export :test-cpp-tree-sitter))
(in-package :software-evolution-library/test/cpp-tree-sitter)
(in-readtable :curry-compose-reader-macros)
(defsuite test-cpp-tree-sitter "C++ tree-sitter representation."
  (cpp-tree-sitter-available-p))


;;; Utility

(defixture trim-front
    (:setup
     (setf *soft*
           (from-string 'cpp-project
                        (read-file-into-string
                         (asdf:system-relative-pathname
                          :software-evolution-library
                          "test/etc/cpp-fragments/trim_front.cc")))))
  (:teardown (nix *soft*)))


;;; Analysis tests

(deftest test-relevant-declaration-type-regression ()
  (let* ((software (from-string 'cpp "int x = 1;"))
         (ast (find-if (of-type 'cpp-declaration) software)))
    (with-attr-table software
      (is (eql 'variable-declaration-ast (relevant-declaration-type ast))))))

(deftest test-cpp-function-name ()
  (is (equal "trim_front"
             (function-name (cpp "std::list<Point> trim_front() {}")))))

(deftest test-cpp-function-outer-declaration ()
  (is (equal "trim_front"
             (source-text
              (only-elt
               (outer-declarations
                (cpp-declarator (cpp "std::list<Point> trim_front() {}"))))))))

(deftest test-cpp-compount-stmt-outer-declaration ()
  (is (null (outer-declarations (cpp "{ int a; int b; }")))))

(deftest test-qualified-parameter-name ()
  (is (member "pts"
              (inner-declarations
               (cpp "fn(std::list<Point>& pts) {}"))
              :test #'equal
              :key #'source-text)))

(deftest test-types-not-in-parameter-names ()
  "Test that identifiers from type declarations are not included as parameter names."
  (is (equal "pts"
             (source-text
              (first
               (parameter-names
                (find-if (of-type 'parameter-ast)
                         (cpp "trim_front(std::list<Point>& pts) {}"))))))))

(deftest test-single-namespace-qualifier ()
  (let* ((cpp (from-string 'cpp-project "A::x;"))
         (id (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (is (equal '("A")
               (mapcar #'source-text
                       (explicit-namespace-qualifiers id))))))

(deftest test-multiple-explicit-namespace-qualifiers ()
  (let* ((cpp (from-string 'cpp-project "A::B::C::x;"))
         (id (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (is (equal '("A" "B" "C")
               (mapcar #'source-text
                       (explicit-namespace-qualifiers id))))))

(deftest test-multiple-explicit-namespace-qualifiers-same-name ()
  (let* ((cpp (from-string 'cpp-project "A::A::x;"))
         (id (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (is (equal '("A" "A")
               (mapcar #'source-text
                       (explicit-namespace-qualifiers id))))))

(deftest test-global-namespace-qualifier ()
  (let* ((cpp (from-string 'cpp-project "::x;"))
         (id (find-if (of-type 'cpp-qualified-identifier) (genome cpp)))
         (qualifiers (explicit-namespace-qualifiers id)))
    (is (eql :global (only-elt qualifiers)))))

(deftest test-namespace-qualify-1 ()
  (let* ((cpp
          (from-string 'cpp-project
                       "namespace A {
  int x = 0;

  int f () {
    return A::x;
  }
}"))
         (qid (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (with-attr-table cpp
      (is (string*= "x = 0" (source-text (get-declaration-ast
                                          :variable qid)))))))

(deftest test-namespace-qualify-2 ()
  (let* ((cpp
          (from-string 'cpp-project
                       "namespace A {
  int x = 0;

  namespace B {
    int f () {
      return A::x;
    }
  }
}"))
         (qid (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (with-attr-table cpp
      (is (string*= "x = 0" (source-text (get-declaration-ast :variable qid)))))))

(deftest test-namespace-qualify-3 ()
  (let* ((cpp
          (from-string 'cpp-project
                       "int x = 1;

  namespace A {
    int x = 2;
    int f () {
      return ::x;
    }
  }"))
         (qid (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (with-attr-table cpp
      (is (string*= "x = 1" (source-text (get-declaration-ast :variable qid)))))))

(deftest test-namespace/nested-qualified-identifier ()
  (let* ((cpp (from-string 'cpp-project
                           "namespace Whatever {
    ::testing::Test x;
}")))
    (with-attr-table cpp
      (is (equal "testing"
                 (namespace
                  (find-if (op (source-text= "Test" _))
                           cpp))))
      (is (equal ""
                 (namespace
                  (find-if (op (source-text= "testing" _))
                           cpp)))))))

(deftest test-qualified-identifier-namespace-with-template ()
  (let* ((cpp (from-string 'cpp-project
                           "namespace Whatever {
    x<a>::y<b>::z<c>;
}")))
    (with-attr-table cpp
      (flet ((find* (name)
               (find-if (op (source-text= name _)) cpp)))
        (is (equal "Whatever" (namespace (find* "x"))))
        (is (equal "Whatever" (namespace (find* "a"))))
        (is (equal "Whatever::x" (namespace (find* "y"))))
        (is (equal "Whatever" (namespace (find* "b"))))
        (is (equal "Whatever::x::y" (namespace (find* "z"))))
        (is (equal "Whatever" (namespace (find* "c"))))))))

(deftest test-namespace-deepest-match ()
  "Check that we return the deepest matching namespace."
  (let* ((cpp
          (from-string 'cpp-project
                       "namespace A {
  int x = 0;

  namespace B {
    namespace A {
      namespace B {
        int x = 1;
        int f () {
          return A::B::x;
        }
      }
    }
  }
}"))
         (qid (find-if (of-type 'cpp-qualified-identifier) (genome cpp))))
    (with-attr-table cpp
      (is (string*= "x = 1" (source-text (get-declaration-ast :variable qid)))))))

(def +trim-front-types+
  '(("trim_front" . "std::list<Point>")
    ("pts" . "std::list<Point>&")
    ;; TODO Should this be const float?
    ("dist" . "float")
    ("result" . "std::list<Point>")
    ("d" . "double")
    ("p1" . "std::list<Point>::iterator")
    ("p2" . "std::list<Point>::iterator")
    ("segdist" . "double")
    ("frac" . "double")
    ("midpoint" . "Point")
    ("next_point" . "Point&"))
  "The types extracted from the trim_front example.")

(deftest test-relevant-declaration-type ()
  (let* ((sw (from-string 'cpp-project "int x = 0;
int myfun1 () { return 1; }
int myfun2 () { return x; }
mytype myfun3 (mytype y) { return y; }"))
         (types
          '(("myfun1" . function-declaration-ast)
            ("myfun2" . function-declaration-ast)
            ("myfun3" . function-declaration-ast)
            ("x" . variable-declaration-ast)
            ("y" . variable-declaration-ast)
            ("mytype" . type-declaration-ast)
            ;; No declarations for primitive types.
            ("int" . nil))))
    (with-attr-table sw
      (iter (for node in-tree (genome sw))
            (when (typep node 'declaration-ast)
              (next-iteration))
            (let ((relevant-type (relevant-declaration-type node))
                  (wanted-type (aget (source-text node) types :test #'equal)))
              (is (eql wanted-type
                       relevant-type)
                  "Wrong type for ~a: wanted ~a, got ~a"
                  node wanted-type relevant-type))))))

(deftest test-reference-headers-available ()
  (is (directory-exists-p
       (asdf:system-relative-pathname
        :software-evolution-library
        "utility/libcxx-src/include"))))

(deftest test-trim-front-types (&key only)
  "Test that we retrieve the correct type for each identifier."
  (with-fixture/attrs trim-front
    (let* ((ids (variable-declaration-ids (genome *soft*)))
           ;; The only key is for interactive testing. E.g. tracing
           ;; inference for a particular variable.
           (ids (if only
                    (filter (op (member _ only :test #'source-text=))
                            ids)
                    ids)))
      (iter (for id in ids)
            (when-let (entry (assoc id
                                    +trim-front-types+
                                    :test #'source-text=))
              (let ((type (infer-type id)))
                (is (source-text= (cdr entry) type)
                    "Inferred ~a for variable ~a, should be ~a"
                    (source-text type)
                    (source-text id)
                    (cdr entry))))))))

(deftest test-expression-type ()
  (is (equal "double"
             (source-text
              (expression-type
               (find-if (of-type 'call-ast)
                        (cpp "static_cast<double>(x);"))))))
  (let ((cpp (from-string 'cpp-project "1.0 + 2.0f;")))
    (with-attr-table cpp
      (is (equal "double"
                 (source-text
                  (infer-type (find-if (of-type 'cpp-binary-expression) cpp)))))))
  (let ((cpp (from-string 'cpp-project "1 + 2.0f;")))
    (with-attr-table cpp
      (is (equal "float"
                 (source-text
                  (infer-type (find-if (of-type 'cpp-binary-expression) cpp))))))))

(deftest test-infer-expression-type ()
  (let* ((cpp (from-string 'cpp-project "int x = fn(b);"))
         (expression (find-if (op (source-text= "fn(b)" _)) cpp)))
    (with-attr-table cpp
      (is (typep expression 'expression-ast))
      (is (equal "int"
                 (source-text
                  (infer-expression-type expression))))))
  (with-fixture/attrs trim-front
    (is (equal "double"
               (source-text
                (infer-expression-type (find-if
                                        (lambda (ast)
                                          (and (typep ast 'expression-ast)
                                               (equal (source-text ast)
                                                      "(dist - d) / segdist")))
                                        (genome *soft*))))))))

(deftest test-cpp-infer-type/compound-literal ()
  (let* ((sw (from-string 'cpp-project "auto x = mytype{1};"))
         (ast (find-if (of-type 'cpp-compound-literal-expression) (genome sw))))
    (with-attr-table sw
      (is (equal (source-text (infer-type ast)) "mytype")))))

(deftest test-cpp-infer-type/auto-literal ()
  (let* ((sw (from-string 'cpp-project "auto x = 1;"))
         (ast (find-if (of-type 'identifier-ast) (genome sw))))
    (with-attr-table sw
      (is (equal (source-text (infer-type ast)) "int")))))

(deftest test-cpp-infer-type/auto-rhs ()
  (let* ((sw (from-string 'cpp-project (fmt "~
int x = 1;
auto y = x;~
")))
         (ast (second (collect-if (of-type 'cpp-identifier) (genome sw)))))
    (with-attr-table sw
      (is (string= "y" (source-text ast)))
      (is (equal "int" (source-text (infer-type ast)))))))

(deftest test-get-declaration-ast/reference ()
  (let* ((sw (from-string 'cpp-project (fmt "int& y = x;")))
         (id (second (collect-if (of-type 'identifier-ast) (genome sw)))))
    (with-attr-table sw
      (is (string= (source-text id) "y"))
      (is (typep (get-declaration-ast :variable id) 'cpp-declaration)))))

(deftest test-get-declaration-ast/pointer ()
  (let* ((sw (from-string 'cpp-project (fmt "int* y = x;")))
         (id (second (collect-if (of-type 'identifier-ast) (genome sw)))))
    (with-attr-table sw
      (is (string= (source-text id) "y"))
      (is (typep (get-declaration-ast :variable id) 'c/cpp-declaration)))))

(deftest test-get-declaration-ast/pointer-expression ()
  (let* ((sw (from-string 'cpp-project (fmt "~
int *x;
x = malloc(sizeof(int));
*x = 42;
int y = *x;
")))
         (y (first (take -2 (collect-if (of-type 'identifier-ast) (genome sw))))))
    (with-attr-table sw
      (is (string= "y" (source-text y)))
      (let ((ptr-expr
             (rhs
              (only-elt
               (cpp-declarator
                (get-declaration-ast :variable y))))))
        (is (equal (source-text (get-declaration-ast :variable ptr-expr))
                   "int *x;"))))))

(deftest test-infer-type/primitive-type-pointer ()
  "Test we can resolve a C++ primitive type as the type of the pointee
of a pointer expression."
  (let* ((sw (from-string 'cpp-project (fmt "~
int *x;
x = malloc(sizeof(int));
*x = 42;
int y = *x;
"))))
    (with-attr-table sw
      (let ((expr (lastcar (collect-if (of-type 'cpp-pointer-expression)
                                       (genome sw)))))
        (is (source-text= "int" (infer-type expr)))))))

(deftest test-get-initialization-ast/assignment ()
  "Test that we get the correct assignment for the initialization AST
of a variable (not just the first succeeding assignment)."
  (let* ((sw (from-string 'cpp-project (fmt "~
int x;
int y;
x = 1;
y = 2;")))
         (y (lastcar (collect-if (lambda (ast)
                                   (and (typep ast 'identifier-ast)
                                        (equal (source-text ast) "y")))
                                 (genome sw)))))
    (with-attr-table sw
      (is (equal "y = 2" (source-text (get-initialization-ast y)))))))

(deftest test-reference-pointer-expression-aliasee ()
  "Test that we get the aliasee for a reference initialized with a
dereferenced pointer."
  (with-fixture/attrs trim-front
    (let* ((sw *soft*)
           (next-point
            (find-if (op (equal (source-text _) "next_point"))
                     (genome sw))))
      (with-attr-table sw
        (is (typep next-point 'identifier-ast))
        (let ((aliasee (aliasee next-point)))
          (is (typep aliasee 'identifier-ast))
          (is (string= "p2" (source-text aliasee)))
          (let ((alias-set (alias-set aliasee)))
            (is (member next-point alias-set))))))))

(def +alias-fragment+
  (fmt "~
{
  int pl = 10;
  int& r = pl;
  int* p = &pl;
  int* q = p;
  int *s;
  s = p;
}"))

(defun test-aliasee-is-plain-var (alias-name)
  (let* ((sw (from-string 'cpp-project +alias-fragment+))
         (pl (find-if (op (equal (source-text _) "pl"))
                      (genome sw)))
         (alias (find-if (op (equal (source-text _) alias-name))
                         (genome sw))))
    (with-attr-table sw
      (is (typep alias 'identifier-ast))
      (finishes
       (get-initialization-ast alias))
      (is (eql pl (aliasee alias))))))

(deftest test-reference-aliasee ()
  (test-aliasee-is-plain-var "r"))

(deftest test-initialized-pointer-aliasee ()
  (test-aliasee-is-plain-var "p"))

(deftest test-pointer-initialized-pointer-aliasee ()
  (test-aliasee-is-plain-var "q"))

(deftest test-unitialized-pointer-aliasee ()
  (test-aliasee-is-plain-var "q"))

(deftest test-alias-set ()
  (let* ((sw (from-string 'cpp-project +alias-fragment+))
         (pl (find-if (op (equal (source-text _) "pl"))
                      (genome sw))))
    (with-attr-table sw
      (is (typep pl 'identifier-ast))
      (is (typep (get-initialization-ast pl)
                 'cpp-init-declarator))
      (is (length= 4 (alias-set pl))))))

(deftest test-infer-auto-type-from-function ()
  (let* ((sw (from-string 'cpp-project (fmt "~
int myfun(int x, int y) {
    return x + y;
}

auto z = myfun(1, 2);")))
         (z (find "z" (identifiers (genome sw))
                  :test #'source-text=)))
    (with-attr-table sw
      (is (typep z 'identifier-ast))
      (is (source-text= "int" (infer-type z))))))

(deftest test-resolve-method-call-to-field-decl ()
  (let* ((sw (from-string 'cpp-project (fmt "~
struct Point {
  double x,y;
  double Distance(const Point&), other_function();
  Point PointAlongSegment(const Point&, double);
};

auto p1 = new Point{0.0, 0.0};
auto p2 = new Point{0.0, 1.0};

auto d = p1->Distance(p2);")))
         (call (find-if (of-type 'call-ast) (genome sw)))
         (field-expr (call-function call)))
    (with-attr-table sw
      (is (string^= "double Distance"
                    (source-text
                     (get-declaration-ast :function field-expr))))
      ;; We get the type of `p1' (`Point').
      (is (source-text= "Point"
                        (infer-type
                         (cpp-declarator
                          (find-if (of-type 'cpp-init-declarator)
                                   (is (get-declaration-ast
                                        :variable
                                        (cpp-argument field-expr)))))))))
    ;; We get the declaration of the `Point' type.
    #+(or) (is (get-declaration-ast 'type sw
                                    (infer-type sw (get-declaration-id
                                                    'variable sw field-expr))))
    ;; We get the declaration of the `Distance' field in `Point'.
    #+(or) (is (typep field-decl 'cpp-field-declaration))
    #+(or) (is (member "Distance" (field-names field-decl)
                       :test #'source-text=))
    ;; Finally we infer the type of the call.
    ;; (is (source-text= "double" (infer-type sw call)))
    ))

(def +iterator-container-type-sw+
  (fmt "~
#include<list>

struct Point {
  double x,y;
  double Distance(const Point&), other_function();
  Point PointAlongSegment(const Point&, double);
};

double myfun(std::list<Point>& pts) {
  auto p1 = pts.cbegin();
  auto po = *p1;
  auto d = p1->Distance(p2);
  return d;
}
"))

(deftest test-infer-field-call-type ()
  "Test that we correctly infer the type of a field expression call
both when it uses a dot (not a dereference) and when it dereferences
with an arrow, even when the infererence passes through both."
  (let* ((sw (from-string 'cpp-project +iterator-container-type-sw+))
         (file-ast (find-if (of-type 'dir:file-ast) (genome sw)))
         (calls (collect-if (of-type 'call-ast) file-ast)))
    (with-attr-table sw
      (is (length= 2 calls))
      (destructuring-bind (call1 call2) calls
        (is (source-text= call1 "pts.cbegin()"))
        (is (source-text= call2 "p1->Distance(p2)"))
        (is (source-text= (infer-type call1) "std::list<Point>::const_iterator"))
        ;; (namespace (infer-type sw call1))
        (is (source-text= (infer-type call2) "double"))))))

(deftest test-resolve-iterator-container-type ()
  "Test that we can resolve the type of the elements of the container
of a std iterator."
  (let ((sw (from-string 'cpp-project +iterator-container-type-sw+)))
    (with-attr-table sw
      (flet ((get-decl (name)
               (get-declaration-id
                :variable
                (find-if (op (source-text= name _)) sw))))
        ;; (is (source-text= "std::list<Point>" (infer-type sw (get-decl "pts"))))
        ;; (is (source-text= "Point" (infer-type sw (get-decl "po"))))
        (is (source-text= "double" (infer-type (get-decl "d"))))
        ;; (is (string*= "iterator"
        ;;               (source-text
        ;;                (infer-type sw (get-decl "p1")))))
        ))))

(deftest test-resolve-method-call-to-iterator-container-type ()
  "Test that can infer the type of the elements of a container of an
iterator from a call on a dereferenced element."
  (let ((sw (from-string 'cpp-project +iterator-container-type-sw+)))
    (with-attr-table sw
      (let* ((call (lastcar (collect-if (of-type 'call-ast)
                                        (find-if (of-type 'dir:file-ast)
                                                 (genome sw)))))
             (field-expr (call-function call))
             (field-decl
              (is (get-declaration-ast :function call))))
        (symbol-table field-decl)
        (is (source-text= "double" (infer-type field-expr)))
        ;; We get the declaration of the `Point' type.
        ;; (is (get-declaration-ast :type sw (infer-type sw field-expr)))
        ;; We get the declaration of the `Distance' field in `Point'.
        (is (typep field-decl 'cpp-field-declaration))
        (is (member "Distance" (field-names field-decl)
                    :test #'source-text=))
        ;; Finally we infer the type of the call.
        (is (source-text= "double" (infer-type call)))))))

(defun find-soft-var (name)
  (find name (identifiers (genome *soft*))
        :test #'source-text=))

(deftest test-assignments ()
  (with-fixture/attrs trim-front
    (flet ((assigned (var) (assignments var)))
      (is (not (assigned (find-soft-var "dist"))))
      (is (assigned (find-soft-var "p1")))
      (is (assigned (find-soft-var "p2")))
      (is (not (assigned (find-soft-var "result"))))
      (is (assigned (find-soft-var "d")))
      (is (not (assigned (find-soft-var "next_point"))))
      (is (not (assigned (find-soft-var "segdist"))))
      (is (not (assigned (find-soft-var "frac"))))
      (is (not (assigned (find-soft-var "midpoint")))))))

(deftest test-collect-arg-uses ()
  (with-fixture/attrs trim-front
    (is (length= 2 (collect-arg-uses *soft* (find-soft-var "next_point"))))
    (is (length= 1 (collect-arg-uses *soft* (find-soft-var "p2"))))
    (is (length= 3 (collect-arg-uses *soft*
                                     (find-soft-var "p2")
                                     t)))
    ;; Regression for a caching issue.
    (is (length= 1 (collect-arg-uses *soft*
                                     (find-soft-var "p2"))))))

(deftest test-collect-arg-uses/pointer ()
  "Test that if a variable is dereferenced in the arg list, it is
  still considered a use."
  (let* ((cpp (from-string 'cpp "int * x = &y; fn1(x); fn2(*x);"))
         (x (find-if (op (source-text= "x" _)) cpp)))
    (with-attr-table cpp
      (is (length= 2 (collect-arg-uses cpp x))))))

(deftest test-infer-type-loop-terminates ()
  (with-fixture/attrs trim-front
    (finishes (infer-type (find-soft-var "midpoint")))))

(deftest test-get-declaration-ast-from-include ()
  (let* ((sw (from-string 'cpp-project (fmt "~
#include<list>

int main() {
  std::list<int> xs = {1, 2, 3};
  int first = xs.front();
}
"))))
    (with-attr-table sw
      (let* ((field (find-if (of-type 'c/cpp-field-expression) (genome sw)))
             (function (get-declaration-ast :function field)))
        (is (source-text= "xs.front" field))
        (is (typep function 'c/cpp-field-declaration))))))

(def +struct-with-methods+
  (fmt "~
struct Point {
  double x,y;
  double Distance(const Point & p) {
    const auto a = this.x - p.y;
    const auto b = this.y - p.y;
    return std::sqrt(a * a + b * b);
  }
};~
"))

(deftest test-auto-resolution-in-method ()
  ;; TODO Infinite loop.
  ;; (let* ((sw (from-string 'cpp-project +struct-with-methods+)))
  ;;   (is (source-text= "double"
  ;;                     (infer-type sw (stmt-with-text sw "a"))))
  ;;   (is (source-text= "double"
  ;;                     (infer-type sw (stmt-with-text sw "b")))))
  )

(deftest test-infer-return-type ()
  (let* ((sw (from-string 'cpp-project +struct-with-methods+)))
    (with-attr-table sw
      (nest (is)
            (source-text= "double")
            (infer-type)
            (stmt-with-text sw "std::sqrt(a * a + b * b)")))))

(deftest test-infer-initializer-list-type-as-expression ()
  (let ((v (from-string 'cpp-project "std::vector<Point> pts = { p1, p2, p3 };")))
    (with-attr-table v
      (is (source-text=
           "std::vector<Point>"
           (infer-type (find-if (of-type 'cpp-initializer-list) v)))))))

(deftest test-lookup-type-from-inside-type ()
  (let* ((sw (from-string 'cpp-project "struct Point {
  double x,y;
  double Distance(const Point & p) {
    const auto a = this.x - p.y;
    const auto b = this.y - p.y;
    return std::sqrt(a * a + b * b);
  }
  Point PointAlongSegment(const Point & p1, const double distance) {
    return new Point(this.x + distance * (p1.x - this.x), this.y + distance * (p1.y - this.y));
  }
};")))
    (with-attr-table sw
      (is (source-text= "double"
                        (infer-type (stmt-with-text (attrs-root*) "a")))))))

(deftest test-for-loop-inner-declarations-no-initializer ()
  (let* ((cpp (from-string 'cpp (fmt "~
for (; next != numbers.end(); ++ii, ++next)
  *next += *ii;
"))))
    (with-attr-table cpp
      (finishes
       (symbol-table
        (lastcar
         (collect-if (of-type 'identifier-ast) cpp)))))))

(deftest test-member-resolution ()
  "Test that (1) members are in scope inside class definitions and (2)
  we properly resolve identifiers when `this' is explicitly used."
  (let* ((cpp (from-string 'cpp (fmt "~
using namespace std;
class A
{
    public:
        int a;

        void f() {
            a = 4;
            do {
                int a = 5;
                cout << a << endl;
                cout << this->a << endl;
            } while (0);
        }
};"))))
    (with-attr-table cpp
      (let* ((as (collect-if (op (source-text= "a" _)) cpp))
             (decls (mapcar (op (get-declaration-ast :variable _))
                            as)))
        (is (every (of-type 'cpp-field-declaration)
                   (take 2 decls)))
        (is (every (of-type 'cpp-declaration)
                   (take 2 (drop 2 decls))))
        (is (typep (lastcar decls) 'cpp-field-declaration))
        decls))))

(deftest test-alias-declaration-in-symbol-table ()
  (let ((cpp (from-string 'cpp (fmt "~
using func = void(*)(int);
void actual_function(int arg) { /* some code */ }
func fptr = &actual_function;~
"))))
    (with-attr-table cpp
      (source-text= "func"
                    (infer-type (lastcar (collect-if (op (source-text= "fptr" _))
                                                     cpp)))))))

(deftest test-compound-literal-infer-type ()
  (let ((cpp (cpp* "Foo{1,2}")))
    (with-attr-table cpp
      (is (source-text=
           "Foo"
           (infer-type
            (find-if (of-type 'cpp-initializer-list) cpp)))))))

(deftest test-cpp-prototype-function-lookup ()
  "Test that function prototypes are included in the symbol table."
  (let* ((cpp (from-string 'cpp (fmt "~
extern int f();
int g() { return f(); }~
")))
         (call (find-if (of-type 'call-ast) cpp)))
    (with-attr-table cpp
      (source-text= "int" (infer-type call)))))

(deftest infer-struct-member-type ()
  "Test inferring the type of a struct member when dereferencing a
pointer to struct."
  (let ((code (from-string 'cpp (fmt "~
struct foo { int x; };
int f(foo* p, foo s) { return p->x + s.x; }"))))
    (with-attr-table code
      (let ((p->x (stmt-with-text code "p->x"))
            (s.x (stmt-with-text code "s.x")))
        (is (every (of-type 'cpp-field-expression) (list p->x s.x)))
        (is (source-text= "int"
                          (infer-type
                           (stmt-with-text code "p->x + s.x"))))
        (is (source-text= "int" (infer-type p->x)))
        (is (source-text= "int" (infer-type s.x)))))))

(deftest test-parameter-initializer ()
  (let ((cpp (cpp* "template <class T> class mem_map {
public:
  // construct with file
  mem_map(const std::string& file_name,
          size_t size,
          int advice = POSIX_MADV_NORMAL,
          bool readonly = false)
      : ptr(nullptr), count(0), file_name(\"\") {
    map(file_name, size, advice, readonly);
  }
}")))
    (with-attr-table cpp
      (infer-type (lastcar (collect-if
                            (op (source-text= _ "advice"))
                            cpp))))))

(deftest test-enum-is-variable-declaration ()
  (let ((cpp (cpp "enum IntersectCase { kWithin, kContains, kOutside, kIntersects };
kWithin;")))
    (with-attr-table cpp
      (infer-type (lastcar (collect-if (op (source-text= _ "kWithin"))
                                       cpp))))))

(deftest test-declaration-in-condition ()
  (let* ((cpp (from-string 'cpp "fn() {
  if (auto item = ptree.get_optional<T>(name))
    value = *item;
}"))
         (expr (stmt-with-text cpp "auto item = ptree.get_optional<T>(name)"))
         (decl (find-if (of-type 'cpp-declaration) expr))
         (item (stmt-with-text decl "item")))
    (with-attr-table cpp
      (is (source-text= "auto" (resolve-declaration-type decl item))))))

(deftest test-lookup-in-scoped-enum ()
  (let* ((cpp (from-string 'cpp "enum class Color { red, green = 20, blue };
Color r = Color::blue;

switch(r)
{
    case Color::red  : std::cout << \"red\n\";   break;
    case Color::green: std::cout << \"green\n\"; break;
    case Color::blue : std::cout << \"blue\n\";  break;
}")))
    (with-attr-table cpp
      (let ((ast (find-if (op (source-text= "Color::blue" _)) cpp)))
        (is (typep ast 'cpp-qualified-identifier))
        (is (typep (get-declaration-ast :variable ast) 'cpp-enumerator))))))

(deftest infer-template-type-through-subsequent-typedef ()
  "Test inferring the types of template members when the template is typedef'd."
  (let ((cpp (from-string 'cpp (fmt "~
class foo<A> { public: int a; int b; };
typedef foo<int> foo_t;
int f(foo_t* p) { return p->a; }~
"))))
    (with-attr-table cpp
      (is (source-text= "int"
                        (infer-type
                         (is (find-if (op (source-text= _ "p->a"))
                                      cpp))))))))

;;; Issue 264
(deftest infer-type-sizeof ()
  "Type of sizeof expressions"
  (let* ((cpp-code (from-string 'cpp "void f() { int x; sizeof x; sizeof(int*); }")))
    (with-attr-table cpp-code
      (let ((s1 (stmt-with-text cpp-code "sizeof x"))
            (s2 (stmt-with-text cpp-code "sizeof(int*)")))
        (is (source-text= "size_t" (infer-type s1)))
        (is (source-text= "size_t" (infer-type s2)))))))

(deftest infer-type-bool-constants ()
  "Types of the boolean constants true and false"
  (let* ((cpp-code (from-string 'cpp "void f() { true; false; }")))
    (with-attr-table cpp-code
      (let ((s1 (stmt-with-text cpp-code "true"))
            (s2 (stmt-with-text cpp-code "false")))
        (is (source-text= "bool" (infer-type s1)))
        (is (source-text= "bool" (infer-type s2)))))))

(deftest test-array-declarator-outer-declarations ()
  (is (typep
       (nest
        (car)
        (outer-declarations)
        (is)
        (find-if (of-type 'cpp-declaration))
        (genome)
        (from-string 'cpp "uint32_t offsets[kBinCount] = {static_cast<uint32_t>(bins[0].size())};"))
       'cpp-identifier)))

(deftest test-variadic-type-parameter-name ()
  (let* ((source "template <typename...> static std::false_type test(...);")
         (cpp (from-string 'cpp source))
         (param (is (find-if (of-type 'parameter-ast) cpp))))
    (is (equal (parameter-name param) "..."))))

(deftest test-cpp-round-trip-anonymous-variadic-parameter ()
  (let* ((source "void foo(...) {};")
         (cpp (from-string 'cpp source)))
    (is (equal source (source-text cpp)))))

(deftest test-anonymous-variadic-parameter-name ()
  (let* ((cpp (from-string 'cpp "void foo(...) {};"))
         (param (is (find-if (of-type 'parameter-ast) cpp))))
    (is (equal (parameter-name param) "..."))))

(deftest test-infer-type-for-templated-struct ()
  (let* ((cpp (from-string 'cpp "template <typename T>
struct Point {
  T x,y;
  Point<T> operator-(const Point<T>& p) const {
    Point<T> p1 = Point<T>{x - p.x, y - p.y}
    return p1;
  }
};"))
         (p1 (find-if (op (source-text= _ "p1"))
                      cpp)))
    (with-attr-table cpp
      (is (typep (get-declaration-ast :type (infer-type p1))
                 'cpp-struct-specifier)))))

(deftest test-infer-type-for-templated-struct-getter ()
  (let* ((cpp (from-string 'cpp "
template<typename T>
struct Point {
  T x, y;
  const T& get_x() {
    return x;
  }
};

int main () {
  const Point<float> p = {1.0, 2.0};
  p.get_x();
  return 0;
}"))
         (getter (find-if (op (source-text= _ "p.get_x()")) cpp)))
    (with-attr-table cpp
      (let ((type (infer-type getter)))
        (is (source-text= type "float"))
        (is (not (typep type 'cpp-type-descriptor)))))))

(deftest test-infer-type-for-templated-struct-member ()
  (let* ((cpp (from-string 'cpp "
template<typename T>
struct Point {
  T x, y;
  const T& get_x() {
    return x;
  }
};

int main () {
  const Point<float> p = {1.0, 2.0};
  p.x;
  return 0;
}"))
         (getter (find-if (op (source-text= _ "p.x")) cpp)))
    (with-attr-table cpp
      (is (source-text= (infer-type getter) "float")))))

(deftest test-enumerator-inner-declaration ()
  "Test that we find the enclosing enumerator as a declaration
  starting from its enclosed ID."
  (let ((cpp (cpp* "enum Unit { IN }")))
    (with-attr-table cpp
      (is (typep
           (get-declaration-ast
            :variable
            (lastcar
             (collect-if (op (source-text= "IN" _))
                         cpp)))
           'cpp-enumerator)))))

(deftest test-field-parameters ()
  (let ((cpp (cpp* "struct s { s add(const s d) const; }")))
    (finishes
     (function-parameters
      (find-if (of-type 'cpp-field-declaration)
               cpp)))))

(deftest test-conditional-type ()
  (let ((cpp (from-string 'cpp "int x = 1;
int y = 2;
int z = fn() ? x : y;")))
    (with-attr-table cpp
      (is (source-text= "int"
                        (infer-type (find-if (of-type 'cpp-conditional-expression)
                                             cpp)))))))

(deftest test-infer-string-type ()
  (let ((cpp (from-string 'cpp "\"x\";")))
    (with-attr-table cpp
      (is (source-text= "const char[2]"
                        (infer-type
                         (find-if (of-type 'cpp-string-literal)
                                  cpp)))))))

(deftest test-enumerator-outer-declaration ()
  (let* ((cpp (from-string 'cpp "enum class Unit { IN, CM };
auto x = Unit::IN;"))
         (in (find-if (op (source-text= _ "Unit::IN")) cpp)))
    (with-attr-table cpp
      (is (typep (get-declaration-ast :variable in)
                 'cpp-enumerator)))))

(deftest test-nested-class-symbol-table ()
  (let ((cpp (from-string 'cpp "struct Distance {
  enum class Unit { IN, CM };
  float x;
  Unit unit;
};")))
    (with-attr-table cpp
      (let ((units (collect-if (op (source-text= _ "Unit")) cpp)))
        (is (length= 2 units))
        (is (typep (get-declaration-ast :type (second units))
                   'cpp-enum-specifier))))))

(deftest test-nested-class-outer-symbol-table ()
  (let ((cpp (from-string 'cpp "struct Distance {
  enum class Unit { IN, CM };
  float x;
  Unit unit;
};
Distance::Unit y;")))
    (with-attr-table cpp
      (let ((unit (find-if (op (source-text= _ "Distance::Unit")) cpp)))
        (is (typep (get-declaration-ast :type unit)
                   'cpp-enum-specifier))))))

(deftest test-lambda-bindings ()
  (let ((cpp (cpp* "[](auto a, auto&& b) { return a < b; }")))
    (with-attr-table cpp
      (is (typep (get-declaration-ast
                  :variable
                  (lastcar (collect-if (op (source-text= "a" _)) cpp)))
                 'cpp-parameter-declaration)))))

(deftest test-lambda/no-parameters ()
  (let ((cpp (cpp* "[] {}")))
    (is (typep cpp 'cpp-lambda-expression))
    (is (null (function-parameters cpp)))))

(deftest test-access ()
  (let ((cpp (from-string 'cpp "class X { int priv; public: int pub; };")))
    (with-attr-table cpp
      (is (equal '(nil t)
                 (mapcar #'public?
                         (collect-if (of-type 'cpp-field-declaration) cpp))))))
  (let ((cpp (from-string 'cpp "struct X { int pub; private: int priv; };")))
    (with-attr-table cpp
      (is (equal '(t nil)
                 (mapcar #'public?
                         (collect-if (of-type 'cpp-field-declaration) cpp))))))
  (let ((cpp (from-string 'cpp "namespace name { int x = 1; }")))
    (with-attr-table cpp
      (is (public? (find-if (of-type 'cpp-declaration) cpp)))))
  (let ((cpp (from-string 'cpp "namespace { int x = 1; }")))
    (with-attr-table cpp
      (is (not (public? (find-if (of-type 'cpp-declaration) cpp)))))))

(deftest test-function-declaration-lookup-from-function ()
  (let* ((cpp (from-string 'cpp "int myadd (int x, int y);
int myadd(int x, int y) {
  return x + y;
}
int sum = myadd(2, 2);"))
         (decl (is (find-if (of-type 'cpp-declaration) cpp)))
         (defn (is (find-if (of-type 'cpp-function-definition) cpp))))
    (with-attr-table cpp
      (is (eql (get-declaration-ast :function defn) decl)))))

(deftest test-exported-from-declaration ()
  (let ((cpp (from-string 'cpp "
export int fun1();
int fun2();
int fun1() { return 1; };
int fun2() { return 2; };
int fun3() { return 3; };
")))
    (with-attr-table cpp
      (let ((fns (collect-if (of-type 'cpp-function-definition)
                             (genome cpp))))
        (is (length= fns 3))
        (is (exported? (first fns)))
        (is (not (exported? (second fns))))
        (is (not (exported? (third fns))))))))

(deftest test-exported-from-block ()
  (let ((cpp (from-string 'cpp "
export {
  int fun1() { return 1; };
}")))
    (with-attr-table cpp
      (is (exported? (find-if (of-type 'cpp-function-definition)
                              cpp))))))

(deftest test-exported-from-namespace ()
  (let ((cpp (from-string 'cpp "
export namespace ns {
  int fun1() { return 1; };
}")))
    (with-attr-table cpp
      (is (exported? (find-if (of-type 'cpp-function-definition)
                              cpp))))))

(deftest test-exported-from-export-over-namespace ()
  (let ((cpp (from-string 'cpp "
export {
  namespace ns {
    int fun1() { return 1; };
  }
}
")))
    (with-attr-table cpp
      (is (exported? (find-if (of-type 'cpp-function-definition)
                              cpp))))))

(deftest test-exported-from-export-over-class-public ()
  (let ((cpp (from-string 'cpp "
export {
  struct A {
    void print();
  };
}
")))
    (with-attr-table cpp
      (is (exported? (is (find-if (of-type 'cpp-field-declaration)
                                  cpp)))))))

(deftest test-not-exported-from-export-over-class-private ()
  (let ((cpp (from-string 'cpp "
export {
  class A {
    void print();
  };
}
")))
    (with-attr-table cpp
      (is (not (exported? (is (find-if (of-type 'cpp-field-declaration)
                                       cpp))))))))

(deftest test-not-exported-from-export-over-anonymous-namespace ()
  (let ((cpp (from-string 'cpp "
export {
  namespace {
    int fun1() { return 1; };
  }
}
")))
    (with-attr-table cpp
      (is (not (exported? (find-if (of-type 'cpp-function-definition)
                                   cpp)))))))


;;; Parsing tests

(deftest test-reference-return ()
  (is (equal "foo"
             (function-name
              (convert 'cpp-ast "int& foo() {}" :deepest t))))
  (let* ((file (asdf:system-relative-pathname
                "software-evolution-library"
                "test/etc/cpp-tree-sitter/reference.cc"))
         (software (sel:from-file 'cpp file))
         (fn (find-if (of-type 'function-ast) (genome software))))
    (is (equal "FileDescriptorTables::GetEmptyInstance"
               (function-name fn)))))

(deftest function-name-on-cpp-tree-sitter ()
  (let ((root (convert 'cpp-ast "void z::y::z() { return; }")))
    (is (equal "z::y::z"
               (function-name (find-if (of-type 'function-ast) root))))))

(deftest preprocessor-test-1 () ;; address sel issue 136
  "Ensure that #ifndef is not converted to #ifdef"
  (let ((*soft* (from-string (make-instance 'cpp) 
"#ifndef BSD4_1
#define HAVE_GETPAGESIZE
#endif
")))
    (is (typep *soft* 'cpp))
    (is (typep (genome *soft*) 'cpp-translation-unit))
    (is (typep (elt (children (genome *soft*)) 0) 'cpp-preproc-ifdef))
    (is (starts-with-subseq
         "#ifndef" (source-text (elt (children (genome *soft*)) 0))))))

(deftest preprocessor-test-2 () ;; address sel issue 136
  "Ensure that #ifdef is not converted to #ifndef"
  (let ((*soft* (from-string (make-instance 'cpp) 
"#ifdef BSD4_1
#define HAVE_GETPAGESIZE
#endif
")))
    (is (typep *soft* 'cpp))
    (is (typep (genome *soft*) 'cpp-translation-unit))
    (is (typep (elt (children (genome *soft*)) 0) 'cpp-preproc-ifdef))
    (is (starts-with-subseq
         "#ifdef" (source-text (elt (children (genome *soft*)) 0))))))

(deftest compound-operator-test-1 () ;; sel issue #137
  (let ((*soft* (from-string (make-instance 'cpp) 
"{ int x = 1; 
   x *= 4; 
   x += 2; 
   x -= 1; 
   x /= 5; }")))
    (is (typep *soft* 'cpp))
    (let ((g (genome *soft*)))
      (is (typep g 'cpp-translation-unit))
      (is (typep (@ g 0) 'cpp-compound-statement))
      (is (typep (@ g '(0 1)) 'cpp-expression-statement))
      (is (typep (@ g '(0 1 0)) 'cpp-assignment-expression))
      (is (string-equal
           (source-text (@ g '(0 1 0 1)))
           "*="))
      (is (string-equal
           (source-text (@ g '(0 2 0 1)))
           "+="))
      (is (string-equal
           (source-text (@ g '(0 3 0 1)))
           "-="))
      (is (string-equal
           (source-text (@ g '(0 4 0 1)))
           "/=")))))
      
(deftest field-expression-test-1 () ;; sel issue #142
  "Ensure that '.' and '->' are handled correctly"
  (let ((*soft* (from-string (make-instance 'cpp) 
"int main ()
{
    typedef struct { int f1; int f2; } X;
    X a[3];
    int i;
    X *p = a;
    p->f1 = 1;
    i = p->f1;
    return i;
}
")))
    (is (typep *soft* 'cpp))
    (let ((g (genome *soft*)))
      (is (typep g 'cpp-translation-unit))
      (is (typep (@ g 0) 'cpp-function-definition))
      (is (typep (@ g '(0 2)) 'cpp-compound-statement))
      (is (typep (@ g '(0 2 4)) 'cpp-expression-statement))
      (is (typep (@ g '( 0 2 4 0)) 'cpp-assignment-expression))
      (is (typep (@ g '(0 2 4 0 0)) 'cpp-field-expression))
      (is (string-equal (source-text  (@ g '(0 2 4 0 0 1)))
                        "->"))
      (is (typep (@ g '(0 2 5)) 'cpp-expression-statement))
      (is (typep (@ g '(0 2 5 0)) 'cpp-assignment-expression))
      (is (typep (@ g '(0 2 5 0 2)) 'cpp-field-expression))
      (is (string-equal (source-text  (@ g '(0 2 5 0 2 1)))
                        "->")))))

(deftest test-variadic-declarator/rvalue-reference ()
  (finishes
   (convert 'cpp-ast
            "iterator emplace(const_iterator position, Args&&... args);")))

(deftest cpp-member-function-definition-delete ()
  "A function member function that is deleted can be parsed and reproduced."
  (let ((source "class A : public B { void operator=(A const&) = delete; };"))
    (is (source-text= source (convert 'cpp-ast source)))))

(deftest cpp-friend-declaration-parses ()
  "A class definition with a friend struct declaration can be parsed and
reproduced as source text."
  (let ((source "class X {friend struct Val;};"))
    (is (source-text= source (convert 'cpp-ast source)))))

(deftest test-cpp-operator-overload-definition-ast ()
  (let* ((cpp (from-string 'cpp "Point operator-(const Point& p) const {
  return Point{x - p.x, y - p.y};
}"))
         (name (definition-name-ast
                (find-if (of-type 'function-declaration-ast)
                         cpp))))
    (is (typep name 'identifier-ast))
    (is (source-text= "operator-" name))))

(deftest test-qualified-definition-ast ()
  (let* ((cpp (from-string 'cpp "::months() const NOEXCEPT
  { return date::months{1}; }"))
         (name (definition-name-ast
                (find-if (of-type 'function-declaration-ast)
                         cpp))))
    (is (typep name 'identifier-ast))
    (is (source-text= "::months" name))))

(deftest test-cpp-destructor-name ()
  (let ((cpp (from-string 'cpp (fmt "~
class Base
{
public:
    virtual ~~Base() {}
};~%"))))
    (is (source-text= "~Base"
                      (definition-name-ast
                       (find-if (of-type 'function-ast) cpp))))))

(deftest test-cpp-operator-cast-name ()
  (let* ((cpp (from-string 'cpp (fmt "~
struct X
{
    // implicit conversion
    operator int() const { return 7; }

    // explicit conversion
    explicit operator int*() const { return nullptr; }
};~%")))
         (fns (collect-if (of-type 'function-ast) cpp)))
    (is (length= 2 fns))
    (is (source-text= "int" (definition-name-ast (first fns))))
    ;; Should this be int*?
    (is (source-text= "int" (definition-name-ast (second fns))))))

(deftest test-cpp-default-constructor-name ()
  (let* ((cpp (from-string 'cpp (fmt "~
class VectorXY {
public:
  /**
   * Default constructor
   */
  VectorXY<PrecisionT>() : x_(0.0), y_(0.0) {
  }
};~%")))
         (fn (find-if (of-type 'function-declaration-ast)
                      cpp)))
    (is (source-text= "VectorXY<PrecisionT>" (definition-name-ast fn)))))

(deftest test-cpp-scoped-enum-specifier ()
  "Test that the class/struct terminal of an enum class is preserved."
  (is (null (cpp-scope (cpp* "enum foo {}"))))
  (is (typep (cpp-scope (cpp* "enum class foo {}")) 'cpp-class))
  (is (typep (cpp-scope (cpp* "enum struct foo {}")) 'cpp-struct)))

(deftest test-cpp-or-mixins ()
  (is (typep (cpp-operator (cpp* "x|y")) 'c/cpp-\|))
  (is (typep (cpp-operator (cpp* "x||y")) 'c/cpp-\|\|)))

(deftest test-parse-module-qualified-name ()
  (finishes (genome (from-string 'cpp "import x.y;"))))


;;;; Rule Substitution tests
;;; These tests that the rule substitutions are working as intended.
;;; These help identify issues when tree-sitter libs are updated upstream.
;;; NOTE: these should be incorporated into a parsing test when one is added
;;;       for Cpp.

(deftest cpp-field-expression-rule-substitution ()
  "The field-expression substitution parses and reproduces source text."
  (let ((source "int a = (x->y < u && z >= w);"))
    (is (equal source (source-text (convert 'c-ast source))))))

(deftest cpp--constructor-specifiers-substitution ()
  "The substitution for -constructor-specifiers parses and
reproduces source text."
  (let ((source "
class MyF
    : public MapF<x::TestMapF, int32,
                      int32, X::Y::Z,
                      X::Y::Z> {
 public:
  constexpr MyF()
      : MyF::MapF(X::Y{}) {}};"))
    (is (equal source (source-text (convert 'cpp-ast source))))))

(deftest cpp-labeled-statement-rule-substitution ()
  (let ((labeled-statement (convert 'cpp-ast "label: break;" :deepest t)))
    (is (equal "label" (source-text (cpp-label labeled-statement))))
    (is (equal "break;" (source-text (cpp-statement labeled-statement))))))

(deftest cpp-for-statement-rule-substitution ()
  (let* ((source "void foo() { for (int i = 0; i<5; i++) { i=i+2; } }")
         (root (convert 'cpp-ast source))
         (for-statement (stmt-with-text root "for" :at-start t)))
    (is (typep (body for-statement) 'compound-ast))))

(deftest cpp-case-statement-rule-substitution ()
  (let* ((source "void foo(int i) { switch (i) { case 1: i++; break; } }")
         (root (convert 'cpp-ast source))
         (case-statement (stmt-with-text root "case" :at-start t)))
    (is (= 2 (length (cpp-statements case-statement))))))

(deftest cpp-preproc-rule-substitution ()
  (let* ((source (fmt "#if UNDEFINED(FOO)~%#define FOO~%#else~%#include <foo.h>~%#endif~%"))
         (root (convert 'cpp-ast source)))
    (is (find-if (of-type 'cpp-#if) root))
    (is (find-if (of-type 'cpp-#define) root))
    (is (find-if (of-type 'cpp-#else) root))
    (is (find-if (of-type 'cpp-#include) root))
    (is (find-if (of-type 'cpp-#endif) root))))

(defun can-parse (lang string)
  (declare (optimize debug))
  (let* ((genome
          (finishes
           (genome (from-string lang string))))
         (new-text (source-text genome)))
    (is (equal string new-text))))

(deftest test-cpp-operator-name ()
  (can-parse 'cpp "bool operator+() {}")
  (can-parse 'cpp "bool operator<() {}")
  (can-parse 'cpp "bool operator>() {}")
  (can-parse 'cpp "bool operator \"\" x() {}")
  (can-parse 'cpp "bool operator new () {}")
  (can-parse 'cpp "bool operator delete[] () {}"))

(deftest test-cpp-field-expression ()
  (can-parse 'cpp "config.put();")
  (can-parse 'cpp "config.put<int>();"))

(deftest test-cpp-virtual-destructor ()
  (can-parse 'cpp "virtual ~NoCost() {}")
  (can-parse 'cpp "class TruckCost : public DynamicCost {
public:

  virtual ~TruckCost();

};"))

(deftest test-cpp-explicit ()
  (can-parse 'cpp "struct B
{
    explicit B(int) { }
    explicit B(int, int) { }
    explicit operator bool() const { return true; }
};"))

(deftest test-cpp-virtual-const-override ()
  (can-parse 'cpp "virtual bool Allowed() const override {}")
  (can-parse 'cpp "virtual bool Allowed() const {}")
  (can-parse 'cpp "virtual bool Allowed() override {}")
  (can-parse 'cpp "virtual bool Allowed() {}"))

(deftest test-cpp-virtual-method-declaration ()
  (can-parse 'cpp "class TruckCost : public DynamicCost {
public:

  virtual bool AllowTransitions() const;
};"))

(deftest test-preserve-access-specifier-keyword ()
  "Private and protected keywords used to become public keywords."
  (can-parse 'cpp "class myclass {
private:
  const std::vector<char> memory_;
};")
  (can-parse 'cpp "class myclass {
protected:
  const std::vector<char> memory_;
};"))

(deftest test-cpp-preserve-unsigned ()
  "Unsigned used to sometimes become signed."
  (can-parse 'cpp "const std::unordered_map<unsigned, valhalla::valhalla_exception_t> error_codes{}")
  (can-parse 'cpp "s.avail_in = static_cast<unsigned int>(uncompressed.size() * sizeof(std::string::value_type));"))

(deftest test-cpp-preserve-const-in-for ()
  "Check that const doesn't disappear in the binding of a for loop."
  (can-parse 'cpp "for (const auto& location : locations) {}"))

(deftest test-cpp-preserve-const-in-optional-param ()
  ;; The first const was disappearing.
  (can-parse 'cpp "const boost::property_tree::ptree&
configure(const boost::optional<std::string>& config = boost::none) {}")
  ;; The second const was disappearing.
  (can-parse 'cpp "virtual void Log(const std::string& message, const std::string& custom_directive = \" [TRACE] \") {}"))

(deftest test-preserve-class-vs-typename ()
  "This was turning class into typename."
  (can-parse 'cpp
             "template <class T> T clamp(T val, const T low, const T high) {
  return std::min<T>(std::max<T>(val, low), high);
}"))

(deftest test-preserve-ref-ref ()
  "Two ampersands were being collapsed into one."
  (can-parse 'cpp "VectorGraphMemory(std::vector<char>&& memory) : memory_(std::move(memory)) {}"))

(deftest test-preserve-operator-cast-specifiers ()
  (can-parse 'cpp
             "struct edge_t {
  GraphId i;
  const DirectedEdge* e;
  operator const GraphId&() const {
    return i;
  }
  operator const DirectedEdge*() const {
    return e;
  }
  operator bool() const {
    return i.Is_Valid() && e;
  }
};"))

(deftest test-preserve-valueness-reference-field-declarator ()
  (can-parse 'cpp "class X {
  const Obj&
};"))

;;; TODO
#+(or)
(deftest test-cpp-stray-comma ()
  "A comma after the last element in a list gets displaced to the next
line, after a comment if there is one."
  ;; From creduce.
  (can-parse 'cpp "::{
               {
     }
      ,     };
")
  (can-parse 'cpp "for (auto* cache : std::vector<x>{
           new y,
       }) {}")
  (can-parse 'cpp "const gurka::ways ways = {
      {\"AB\", {{\"highway\", \"service\"}}},
  };")
  ;; In this one the comma ends up after the comment.
  (can-parse 'cpp "const constexpr PointLL::first_type DOUGLAS_PEUCKER_THRESHOLDS[19] = {
    2.6,      // z18
};
"))

#+(or)
(deftest test-weird-indent ()
  ;; The body gets too much indentation.
  (can-parse 'cpp "void fun() {
  for (int i = 0;
       i < 100; i++) {
    foo();
  }
}")
  ;; Only the first else-if clause gets indented.
  (can-parse 'cpp "OpenLR::LocationReferencePoint::FormOfWay get_fow(const baldr::DirectedEdge* de) {
  if (de->classification() == valhalla::baldr::RoadClass::kMotorway)
    return OpenLR::LocationReferencePoint::MOTORWAY;
  else if (de->roundabout())
    return OpenLR::LocationReferencePoint::ROUNDABOUT;
  else if (de->use() == valhalla::baldr::Use::kRamp ||
           de->use() == valhalla::baldr::Use::kTurnChannel)
    return OpenLR::LocationReferencePoint::SLIPROAD;
  else if ((de->forwardaccess() & kVehicularAccess) && (de->reverseaccess() & kVehicularAccess))
    return OpenLR::LocationReferencePoint::MULTIPLE_CARRIAGEWAY;
  else if ((de->forwardaccess() & kVehicularAccess) || (de->reverseaccess() & kVehicularAccess))
    return OpenLR::LocationReferencePoint::SINGLE_CARRIAGEWAY;

  return OpenLR::LocationReferencePoint::OTHER;
}"))

(deftest cpp-declaration-specifiers ()
  "Attribute Declarations can be parsed."
  (let ((source "[[maybe_unused]] x var = y;"))
    (is (equal (source-text (convert 'cpp-ast source))
               source))))


;;; Contextualize-ast Tests
(defun contextualization-check (source target-ast-type
                                &key result-type unexpected-type
                                  (target-ast-position 0))
  (let* ((root (convert 'cpp-ast source))
         (software (make-instance 'cpp :genome root))
         (target-ast
           (nth
            target-ast-position
            (collect-if (of-type target-ast-type) root)))
         (result
          (with-attr-table root
            (contextualize-ast software target-ast)))
         (result-root (mapcar (lambda (ast)
                                (if (eq ast target-ast)
                                    result
                                    ast))
                              root)))
    (is (equal (source-text target-ast) (source-text result)))
    (is (equal source (source-text result-root)))
    (when result-type
      (is (typep result result-type)))
    (when unexpected-type
      (is (not (find-if (of-type unexpected-type) result))))))

(deftest cpp-contextualize-function-declarator-1 ()
  "Contextualize-ast turns a function-declarator into an init declarator and
doesn't contain any abstract function parameters or type identifiers."
  (contextualization-check
   "void f () {
  Obj object(a, X(b, Y<1,2>()), Y());
}"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-init-declarator
   :unexpected-type '(or cpp-abstract-function-declarator cpp-type-identifier)))

(deftest cpp-contextualize-function-declarator-2 ()
  "Contextualize-ast doesn't alter declarations that are part of a function
definition (excluding the body)."
  (contextualization-check
   "void f () {
  Obj object(a, X(b, Y<1,2>()), Y());
}"
   'cpp-function-declarator
   :target-ast-position 0
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-3 ()
  "Contextualize-ast doesn't alter declarations that have trailing specifiers."
  (contextualization-check
   "void f () {
  Obj object(a, X(b, Y<1,2>()), Y()) override;
}"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-4 ()
  "Contextualize-ast doesn't alter declarations that have a parameter with a type
and an identifier."
  (contextualization-check
   "void f () {
  Obj object(int a, X(b, Y<1,2>()), Y());
}"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-5 ()
  "Contextualize-ast doesn't alter declarations that have an optional parameter."
  (contextualization-check
   "void f () {
  Obj object(a, int b = 0);
}"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-6 ()
  "Contextualize-ast doesn't alter declarations that have a parameter with
specializers."
  (contextualization-check
   "void f () {
  Obj object(const a);
}"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-7 ()
  "Contextualize-ast doesn't alter declarations that are in a class definition."
  (contextualization-check
   "class Obj {
  Obj get_obj();
};"
   'cpp-function-declarator
   :result-type 'cpp-function-declarator
   :unexpected-type 'cpp-init-declarator))

(deftest cpp-contextualize-function-declarator-context-1 ()
  "Contextualize-ast turns a function-declarator into an init declarator when
it doesn't contain any valid types."
  (contextualization-check
   "int myfun () { Obj object(a, x = 10); }"
   'cpp-function-declarator
   :target-ast-position 1
   :result-type 'cpp-init-declarator
   :unexpected-type '(or cpp-abstract-function-declarator
                      cpp-type-identifier cpp-optional-parameter-declaration)))

(deftest cpp-contextualize-binary-expression-1 ()
  "Contextualize-ast turns a binary expression into a cast expression when
the left hand side is a parenthesized identifier and doesn't contain
parenthesized expressions or binary expressions."
  (contextualization-check
   "struct Type {};
(Type) * variable;"
   'cpp-binary-expression
   :result-type 'cpp-cast-expression
   :unexpected-type '(or cpp-binary-expression cpp-parenthesized-expression)))

(deftest cpp-contextualize-call-expression-1 ()
  "Contextualize-ast turns a call expression into a cast expression."
  (contextualization-check
   "struct Type{};
(Type)(*var());"
   'cpp-call-expression
   :result-type 'cpp-cast-expression))

(deftest cpp-contextualize-binary-expression-2 ()
  "Contextualize-ast maintains the source representation of a binary expression
when it is contextualized."
  (contextualization-check "(Type) * variable ;" 'cpp-binary-expression))

(deftest cpp-contextualize-binary-expression-3 ()
  "Contextualize-ast does nothing when the parent AST is a sizeof expression."
  ;; NOTE: this should be a temporary fix until precedence issues are addressed
  ;;       upstream.
  (contextualization-check
   "sizeof(Type) * variable ;"
   'cpp-binary-expression
   :result-type 'cpp-binary-expression
   :unexpected-type 'cpp-cast-expression))

(deftest cpp-contextualize-binary-expression-context-1 ()
  "Contextualize-ast turns a binary expression into a cast expression when
the left hand side is a type and the binary operator is also a valid prefix
operator."
  (contextualization-check
   "struct Type {};
(Type) * variable;"
   'cpp-binary-expression
   :result-type 'cpp-cast-expression
   :unexpected-type '(or cpp-binary-expression cpp-parenthesized-expression)))


;;; Canonical-type Tests
(defmacro with-canonicalize-type-test
    ((source &key (target-ast-type 'cpp-declaration))
     &body body)
  `(let* ((root (convert 'cpp-ast ,source))
          (target-ast (find-if (of-type ',target-ast-type) root))
          (result (canonicalize-type target-ast))
          (declarator-list (declarator result))
          (specifier-list (specifier result))
          (bitfield (bitfield result)))
     (declare (ignorable declarator-list specifier-list bitfield))
     (labels ((test-declarator-type (key type)
                "Test that the value associated with KEY is of TYPE."
                (is (equal (find-if (of-type type) root)
                           (car (aget key declarator-list)))))
              (test-bitfield-type (type)
                "Test that the AST in the bitfield list is of TYPE."
                (is (equal (find-if (of-type type) root)
                           bitfield))))
       (declare (ignorable (function test-declarator-type)
                           (function test-bitfield-type)))
       ,@body)))

(deftest cpp-canonicalize-type-1 ()
  "Canonicalize-type returns the size in the alist of :declarator."
  (with-canonicalize-type-test ("int x [100];")
    (test-declarator-type :array 'cpp-number-literal)))

(deftest cpp-canonicalize-type-2 ()
  "Canonicalize-type returns the parameter list in the alist of :declarator."
  (with-canonicalize-type-test ("int x (int, int);")
    (test-declarator-type :function 'cpp-parameter-list)))

(deftest cpp-canonicalize-type-3 ()
  "Canonicalize-type returns the qualifiers in the alist of :declarator."
  (with-canonicalize-type-test ("const int *x;")
    (test-declarator-type :pointer 'cpp-const)))

(deftest cpp-canonicalize-type-4 ()
  "Canonicalize-type returns works on a field declaration."
  (with-canonicalize-type-test ("struct s { const int x : 4; };"
                                :target-ast-type cpp-field-declaration)
    (test-bitfield-type 'cpp-number-literal)
    (is (equal (source-text (car specifier-list))
               "const"))))

(deftest cpp-canonicalize-type-5 ()
  "Canonicalize-type returns works on a function definition."
  (with-canonicalize-type-test ("int x (int x, int y) { return x + y; }"
                                :target-ast-type cpp-function-definition)
    (test-declarator-type :function 'cpp-parameter-list)))

(deftest cpp-canonicalize-type/optional-parameter ()
  "Canonicalize-type returns works on a function definition with optional parameters."
  (with-canonicalize-type-test ("int x (int x = 3, int y = 4) { return x + y; }"
                                :target-ast-type cpp-function-definition)
    (test-declarator-type :function 'cpp-parameter-list)))

(deftest cpp-canonicalize-type-6 ()
  "Canonicalize-type returns works on a parameter declaration."
  (with-canonicalize-type-test ("int x (const int *x) { return x + y; }"
                                :target-ast-type cpp-parameter-declaration)
    (test-declarator-type :pointer 'cpp-const)))

(deftest cpp-canonicalize-type-7 ()
  "Canonicalize-type adds implicit int to the end of the specifier list."
  (with-canonicalize-type-test ("short x;")
    (is (equal (source-text (first specifier-list)) "short"))
    (is (equal (source-text (second specifier-list)) "int"))))

(deftest cpp-canonicalize-type-specifier-list-1 ()
  "Canonicalize-type returns the implicit 'int' in the specifier list."
  (with-canonicalize-type-test ("long long x;")
    (is (equal (source-text (find-if (of-type 'cpp-primitive-type)
                                     specifier-list))
               "int"))))

(deftest cpp-canonicalize-type-specifier-list-2 ()
  "Canonicalize-type removes the 'signed' qualifier from the specifier list."
  (with-canonicalize-type-test ("signed long long x;")
    (is (not (find-if (of-type 'cpp-signed) specifier-list)))))

(deftest cpp-canonicalize-type-specifier-list-3 ()
  "Canonicalize-type removes duplicate information from the specifier list."
  (with-canonicalize-type-test
      ("extern extern signed volatile volatile long long x;")
    (is (= 1 (count-if (of-type 'cpp-type-qualifier) specifier-list)))
    (is (= 1 (count-if (of-type 'cpp-storage-class-specifier) specifier-list)))))

(deftest cpp-canonicalize-type-bitfield-1 ()
  "Canonicalize-type handles a null bitfield in a field declaration."
  (with-canonicalize-type-test
      ("struct Point {
  Point PointAlongSegment(const Point&, double);
};" :target-ast-type cpp-field-declaration)
    ;; The first test is that we get here without an error.
    (is (null bitfield))))

(defun is-canonical-type= (ast1 ast2)
  "Test whether AST1 and AST2 are canonical-type=."
  (is (canonical-type= (canonicalize-type ast1) (canonicalize-type ast2))))

(defun is-not-canonical-type= (ast1 ast2)
  "Test whether AST1 and AST2 are not canonical-type=."
  (is (not (canonical-type= (canonicalize-type ast1) (canonicalize-type ast2)))))

(defmacro with-canonical-type=-test
    ((source1 source2 &key (target-type ''cpp-declaration)) &body body)
  `(let* ((type-predicate (of-type ,target-type))
          (target-ast1 (find-if type-predicate (convert 'cpp-ast ,source1)))
          (target-ast2 (find-if type-predicate (convert 'cpp-ast ,source2))))
     (declare (ignorable target-ast1 target-ast2))
     ,@body))

(defun canonicalize-type=-test (source1 source2
                                &key (target-type 'cpp-declaration))
  "Test that SOURCE1 is canonical-type= to itself and that SOURCE2 is not
canonical-type= to SOURCE1."
  (with-canonical-type=-test (source1 source2 :target-type target-type)
    (is-canonical-type= target-ast1 target-ast1)
    (is-not-canonical-type= target-ast1 target-ast2)))

(deftest cpp-canonical-type=-1 ()
  "Canonical-type= compares function types."
  (canonicalize-type=-test "int x (double, float);"
                           "int x (double, double);"))

(deftest cpp-canonical-type=-2 ()
  "Canonical-type= compares array types."
  (canonicalize-type=-test "int x [100];"
                           "int x [10];"))

(deftest cpp-canonical-type=-3 ()
  "Canonical-type= compares pointer types."
  (canonicalize-type=-test "const int *x;"
                           "const int **x;"))

(deftest cpp-canonical-type=-4 ()
  "Canonical-type= compares a combination of array, pointer, and function
parts in types."
  (canonicalize-type=-test "const int *x [3](int a, float y);"
                           "const int **x [10](short a, double y);"))

(deftest cpp-canonical-type=-5 ()
  "Canonical-type= correctly compares specifier lists that have
different orders."
  (with-canonical-type=-test ("const long long int x;"
                              "long long const x;")
    (is-canonical-type= target-ast1 target-ast2)))

(deftest cpp-canonical-type=-6 ()
  "Canonical-type= compares the bitfields of declarations."
  (canonicalize-type=-test "struct x { int x : 4; };"
                           "struct y { int f : 5; };"
                           :target-type 'cpp-field-declaration))

(deftest cpp-canonical-type=-7 ()
  "Canonical-type= compares nested function types."
  (with-canonical-type=-test ("void f1 (int g1(float, double), h1(int(x, y)));"
                              "void f2 (int g2(float, double), h1(int(x, y)));")
    (is-canonical-type= target-ast1 target-ast2)))


;;; Symbol table

(deftest test-strip-template-arguments ()
  "Nested template arguments are properly stripped."
  (is (equal "hash"
             (strip-template-arguments "hash<std::vector<bool, Allocator>>")))
  (is (equal "operator<" (strip-template-arguments "operator<")))
  (is (equal "operator<<" (strip-template-arguments "operator<<"))))

(deftest cpp-symbol-table-1 ()
  "Symbol-table contains qualified identifiers."
  (let* ((source "int x; namespace a { int y; namespace b { int z; } } return;")
         (root (convert' cpp-ast source))
         (target-ast (find-if (of-type 'cpp-return-statement) root)))
    (with-attr-table root
      (is (equal? (symbol-table target-ast)
                  (convert
                   'fset:map
                   `((:variable
                      .
                      ,(fset:map
                        ("x" (list (stmt-with-text root "x")))
                        ("a::y" (list (stmt-with-text root "y")))
                        ("a::b::z" (list (stmt-with-text root "z"))))))))))))

(deftest cpp-symbol-table-2 ()
  "Symbol-table contains all functions that are in scope."
  (let* ((source "void x (int y) { } void x (float y) {  } return;")
         (root (convert' cpp-ast source))
         (target-ast (find-if (of-type 'cpp-return-statement) root)))
    (with-attr-table root
      (is (equal? (symbol-table target-ast)
                  (convert
                   'fset:map
                   `((:function
                      .
                      ,(fset:map
                        ("x" (collect-if (op (equal (source-text _) "x"))
                                         root)))))))))))

(deftest test-qualified-name-variants ()
  (is (equal '("x") (qualified-name-variants "x")))
  (is (equal '("x::y" "y") (qualified-name-variants "x::y")))
  (is (equal '("x::y::z" "x::z" "z") (qualified-name-variants "x::y::z"))))

(deftest cpp-test-nested-namespace-lookup ()
  "Test that we \"inherit\" definitions from the surrounding namespace."
  (let* ((source (fmt "~
enum class Unit { IN, CM };

struct Distance {
  Unit unit;
};

Unit getUnit(Distance& d) {
    return d.unit;
}"))
         (cpp (from-string 'cpp source)))
    (with-attr-table cpp
      (is (typep
           (get-declaration-ast
            :type
            (infer-type (lastcar (collect-if (op (source-text= _ "d.unit"))
                                             cpp))))
           'cpp-enum-specifier)))))

(deftest test-template-parameters-as-type-declaration ()
  "Test that template type parameters are treated as type declarations."
  (let* ((cpp (from-string 'cpp "template <typename T>
T plus (T x, T y) {
  return x+y;
}"))
         (x (lastcar (collect-if (op (source-text= "x" _))
                                 cpp))))
    (with-attr-table cpp
      (let ((x-type (infer-type x)))
        (is (source-text= x-type "T"))
        (is (typep (get-declaration-ast :type (infer-type x))
                   'cpp-type-parameter-declaration))))))

(deftest test-extract-template-type-parameters ()
  ;; See https://en.cppreference.com/w/cpp/language/template_parameters.
  (let ((alist
         '(("template<auto n>
struct B { /* ... */ };")
           ("template<auto...>
struct C {};")
           ("template<A a>
void f();")
           ("template<class T>
class My_vector { /* ... */ };"
            "T")
           ("template<class T = void>
struct My_op_functor { /* ... */ };"
            "T")
           ("template<typename... Ts>
class My_tuple { /* ... */ };"
            "Ts")
           ("template<class>
class My_vector;")
           ("template<class = void>
struct My_op_functor;")
           ("template<typename...>
class My_tuple;")
           ("template<typename T, typename U>
concept C3 = true;"
            "T" "U")

           ("template<typename K, typename V, template<typename> typename C = my_array>
class Map
{
    C<K> key;
    C<V> value;
};"
            "K" "V" "C")
           ("template<class T, int N>
class Y;"
            "T"))))
    (iter (for (template-string . types) in alist)
          (let ((template
                 (find-if (of-type 'cpp-template-declaration)
                          (convert 'cpp-ast template-string))))
            (is (typep template 'cpp-template-declaration)
                "No template in:~%~a" template-string)
            (let ((param-types
                   (sel/sw/ts::template-parameter-types
                    template)))
              (is (set-equal types param-types
                             :test #'source-text=)
                  "Template defines ~a but got ~a:~%~a"
                  types param-types template-string))))))

(deftest test-export-block-symbol-table ()
  (let ((cpp (from-string 'cpp "module;

export module cram_a:interface_part;
export {
    class A {
      public :
        int x, y;
        A (int, int);
        void print ();
    };
}
")))
    (with-attr-table cpp
      (is (not (empty? (symbol-table (genome cpp))))))))


;;; Module tests

(deftest test-symbol-table-union/exports ()
  (let* ((pub-fun1 (cpp* "export int pub_fun1() {}"))
         (pub-fun2 (cpp* "export int pub_fun2() {}"))
         (priv-fun1 (cpp* "int priv_fun1() {}"))
         (priv-fun2 (cpp* "int priv_fun2() {}"))
         (union
          (symbol-table-union
           (make 'cpp-ast)
           (fset:map
            (:function
             (fset:map ("pub_fun1" pub-fun1)
                       ("priv_fun1" priv-fun1)))
            (:export
              (fset:map
               (:function
                (fset:map ("pub_fun1" pub-fun1))))))
           (fset:map
            (:function
             (fset:map ("pub_fun2" pub-fun2)
                       ("priv_fun2" priv-fun2)))
            (:export
              (fset:map
               (:function
                (fset:map ("pub_fun2" pub-fun2)))))))))
    (assert (equal? (@ union :export)
                    (fset:map
                     (:function
                      (fset:map ("pub_fun1" pub-fun1)
                                ("pub_fun2" pub-fun2))))))))

(deftest test-filter-exports ()
  (mvlet* ((cpp
            (from-string 'cpp "export module foo;
struct private_type {};
export struct public_type {};

int private_fun(int x, int y) { return x + y; };
export int public_fun(int x, int y) { return x + y; };"))
           (symtab
            (with-attr-table cpp
              (@ (symbol-table (genome cpp) (empty-map)) :export))))
    (is (@ (@ symtab :function) "public_fun"))
    (is (not (@ (@ symtab :function) "private_fun")))
    (is (not (@ (@ symtab :type) "private_type")))
    (is (@ (@ symtab :type) "public_type"))))

(deftest test-filter-exports/fragment ()
  (let ((cpp (from-string 'cpp "module;
export module b;
export void say_hello() { std::cout << \"Hello\" << std::endl; }
void say_goodbye() { std::cout << \"Goodbye\" << std::endl; }
")))
    (with-attr-table cpp
      (let ((symtab (@ (symbol-table (genome cpp)) :export)))
        (is (@ (@ symtab :function) "say_hello"))
        (is (not (@ (@ symtab :function) "say_goodbye")))))))

(deftest test-filter-exports/namespace ()
  (let ((cpp (from-string 'cpp "module;
export module b;
namespace b {
  export void say_hello() { std::cout << \"Hello\" << std::endl; }
  void say_goodbye() { std::cout << \"Hello\" << std::endl; }
}")))
    (with-attr-table cpp
      (let ((symtab (@ (symbol-table (genome cpp)) :export)))
        (is (@ (@ symtab :function) "b::say_hello"))
        (is (not (@ (@ symtab :function) "b::say_goodbye")))))))

(deftest test-classify-module ()
  (let ((m (module? (from-string 'cpp "export module foo;"))))
    (is (typep m 'primary-module-interface-unit))
    (is (equal "foo" (module-unit-full-name m))))
  (let ((m (module? (from-string 'cpp "module foo;"))))
    (is (typep m 'anonymous-implementation-unit))
    (is (equal "foo" (module-unit-full-name m))))
  (let ((m (module? (from-string 'cpp "export module foo:bar;"))))
    (is (typep m 'module-partition-interface-unit))
    (is (equal "foo" (module-unit-module-name m)))
    (is (equal "bar" (module-unit-partition-name m)))
    (is (equal "foo:bar" (module-unit-full-name m))))
  (let ((m (module? (from-string 'cpp "module foo:bar;"))))
    (is (typep m 'module-partition-implementation-unit))
    (is (equal "foo" (module-unit-module-name m)))
    (is (equal "bar" (module-unit-partition-name m)))
    (is (equal "foo:bar" (module-unit-full-name m))))
  (let ((m (module? (from-string 'cpp "module foo.bar:quux;"))))
    (is (typep m 'module-partition-implementation-unit))
    (is (equal "foo.bar" (module-unit-module-name m)))
    (is (equal "quux" (module-unit-partition-name m)))
    (is (equal "foo.bar:quux" (module-unit-full-name m)))))


;;; Conversion tests

(deftest id-conversions ()
  (let ((types '(cpp-identifier cpp-namespace-identifier cpp-type-identifier)))
    (dolist (type1 types)
      (dolist (type2 types)
        (is (typep (convert type1 (make type2 :text "foo"))
                   type1))))))


;;; patch-whitespace tests

(defun check-patch-whitespace (cpp)
  (let ((ast (convert 'cpp-ast cpp :deepest t)))
    (is (not (typep ast 'source-text-fragment)))
    (is (equal cpp (source-text (patch-whitespace ast :prettify t))))))

(deftest test-cpp-patch-whitespace ()
  (check-patch-whitespace "static_cast<double>(x + y);")
  (check-patch-whitespace "import :foo;")
  (check-patch-whitespace "std::cout << x;")
  (check-patch-whitespace "std::vector<Point> result;")
  (check-patch-whitespace "pts.clear();")
  (check-patch-whitespace "Point p1{0.0, 0.0};")
  (check-patch-whitespace (fmt "#define IDENTITY(x) x~%"))
  (check-patch-whitespace "export module mymod:part;")
  (check-patch-whitespace "struct foo {};")
  (check-patch-whitespace "i++;")
  (check-patch-whitespace "++i;")
  (check-patch-whitespace "i--;")
  (check-patch-whitespace "--i;")
  (check-patch-whitespace "x.y;")
  (check-patch-whitespace "x->y;")
  (check-patch-whitespace "x & y;")
  (check-patch-whitespace "*x;")
  (check-patch-whitespace "x * y;")
  (check-patch-whitespace "+x;")
  (check-patch-whitespace "x + y;")
  (check-patch-whitespace "-x;")
  (check-patch-whitespace "x - y;")
  (check-patch-whitespace "~x;")
  (check-patch-whitespace "!x;")
  (check-patch-whitespace "this->x;")
  (check-patch-whitespace "this.x;")
  (check-patch-whitespace "{};")
  (check-patch-whitespace (fmt "switch (1) {~%~4tdefault:~%~8tbreak;~%}")))
