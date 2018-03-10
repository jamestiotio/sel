;;; Specialization for building a software object from a java project
;;;
;;; Implements the core functionality of the software-evolution-library
;;; for class files written in java. The java versions that are supported
;;; relies heavily on an input's success of parsing individual files with
;;; @uref{http://javaparser.org/, Java Parser}.
;;;
;;; The project will use jar files to extract which files need to be
;;; initialized in this context. A java-project will contain relative
;;; path names and the corresponding software object, stored in
;;; evolve-files. Naturally, the java software object is used in this
;;; implementation.
;;;
;;; The core functionality is supported by the command line tool
;;; @uref{https://github.com/GrammaTech/java-mutator, java-mutator}.
;;;
;;; Note: certain methods in this class are over-loaded to provide consistency
;;; with other software objects, but are not used in this implementation.
;;;
;;; @texi{java-project}
(in-package :software-evolution-library)
(in-readtable :curry-compose-reader-macros)

(define-software java-project (project)
  ((project-dir :initarg :project-dir
                :accessor project-dir
                :initform nil
                :documentation "Source directory containing the project")
   (java-class  :initarg :java-class
                :accessor java-class
                :initform 'java
                :documentation "Java subclass to utilize in the project")))

(defmethod from-file ((obj java-project) project-dir)
  "Java-project from-file builds the project, extracts relevant
   java files in project and creates java software object for
   each and stores them in a list."
  (note 3 "Initializing Java project")
  (setf (slot-value obj 'project-dir) project-dir)
  (with-temp-build-dir (project-dir)
    (multiple-value-bind (stdout stderr exit-code)
      (shell "cd ~a && ~a ~a"
             *build-dir* (build-command obj) (build-target obj))
      (if (not (zerop exit-code))
          (error "Failed to build java project for project.~%~
                  build-command: ~a ~a~%~
                  stdout: ~a~%~
                  stderr: ~a~%"
                  (build-command obj)
                  (build-target obj)
                  stdout stderr)
          (let* ((jar-path (merge-pathnames-as-file *build-dir*
                                                    (build-target obj)))
                 (files (get-applicable-project-files jar-path *build-dir*))
                 (num-files (list-length files)))
                (note 3 "~a project files identified" num-files)
                (note 3 "Starting java software object initialization")
                (setf (slot-value obj 'evolve-files)
                      (iter (for entry in files)
                            (for i upfrom 1)
                            (note 3 "Initializing ~a" entry)
                            (note 4 "Software object ~
                                    initialization progress: ~a/~a"
                                    i
                                    num-files)
                            (let ((evolve-index
                                    (replace-all
                                      entry
                                      (-> (if *build-dir*
                                              *build-dir*
                                              (project-dir obj))
                                          (cl-fad:pathname-as-directory)
                                          (namestring))
                                      "")))
                            (handler-case
                              (collect
                                (cons
                                  evolve-index
                                  (from-file (make-instance (java-class obj))
                                             entry)))
                              (mutate (e)
                                (declare (ignorable e))
                                (note 3 "Failed to initialize object, ~
                                         ignoring file ~a"
                                        evolve-index))))))))))
  (note 3 "~a files are applicable for mutation"
          (list-length (slot-value obj 'evolve-files)))
  obj)

(defmethod to-file ((java-project java-project) path)
  (note 3 "Writing project to path ~a" path)
  (let ((*build-dir* (make-build-dir (project-dir java-project) :path path)))
    (write-genome-to-files java-project)))

(defun get-filename (path)
  "Return filename of a path"
  (pathname-name (pathname path)))

(defun extract-filename-list (pathList)
  "Return a list of filenames for a list of full paths"
  (mapcar #'get-filename pathList))

(defun extract-jars-in-jar(folder jar-name)
  "Extracts jars within the jar passed to the function
   and returns the list of jars extracted for the next
   extraction iteration"
  (note 3 "Extracting jars from ~a" jar-name)
  (multiple-value-bind (stdout)
    (shell "unzip -jo ~a/~a '*\.jar' -d ~a" folder jar-name folder)
    (let ((stdout-str (make-array '(0)
                                   :element-type
                                   #+sbcl 'extended-char
                                   #-sbcl 'character
                                   :fill-pointer 0 :adjustable t)))
         (with-output-to-string (stdout stdout-str)
           (run-program (format nil "jar tf ~a/~a | grep -o '[^/]*.jar$'"
                          folder
                          jar-name)
                        :force-shell t
                        :ignore-error-status t
                        :output stdout))
      (let ((jar-files
              (split-sequence #\Newline
                              (string-trim '(#\Newline) stdout-str))))
           ;; If first element is empty string, set as empty list
           (if (equal (car jar-files) "") (setf jar-files nil))
           (note 3 "Extracted ~a jars from ~a"
                 (list-length jar-files)
                 jar-name)
           jar-files))))

(defun get-files-project-folder (project-path)
  "Returns a list of all files with ext java"
  (note 3 "Extracting java files from project folder")
  (let ((stdout-str (make-array '(0)
                                 :element-type
                                 #+sbcl 'extended-char
                                 #-sbcl 'character
                                 :fill-pointer 0 :adjustable t)))
    (with-output-to-string (stdout stdout-str)
      (run-program (format nil "find ~a -type f -name '*\.java'" project-path)
                   :force-shell t
                   :ignore-error-status t
                   :output stdout)
      (let ((project-files
              (split-sequence #\Newline
                              (string-trim '(#\Newline) stdout-str))))
           (note 3 "~a java files found in project folder"
                 (list-length project-files))
           project-files))))

(defun get-files-jar (jar-path)
  "Returns a list of class files in a jar,
   Jars within jars are recursivly extracted
   to the depth of 3 within the built jar"
  (note 3 "Extracting jars within built jar")
  (with-temp-dir (sandbox)
    (multiple-value-bind (stdout stderr errno)
      (shell "cp ~a ~a" jar-path sandbox)
      (declare (ignorable stdout stderr errno)))
    (let* ((paths (list (format nil "~a.~a"
                                (pathname-name (pathname  jar-path))
                                (pathname-type (pathname jar-path))))))
          (loop for i from 1 to 4
            do (setf paths
                     (flatten
                       (loop for path in paths
                             collect (extract-jars-in-jar sandbox path))))))
    (let ((stdout-str (make-array '(0)
                                  :element-type
                                  #+sbcl 'extended-char
                                  #-sbcl 'character
                                  :fill-pointer 0
                                  :adjustable t)))
      (with-output-to-string (stdout stdout-str)
        (run-program (format nil "ls ~a" sandbox)
                    :force-shell t
                    :ignore-error-status t
                    :output stdout))
      (let ((jar-files (split-sequence
                         #\Newline
                         (string-trim '(#\Newline) stdout-str))))
        (note 3 "~a jar files extracted from built jar"
              (- (list-length jar-files) 1))
        (let ((class-files
                (flatten
                  (loop
                    for jar-file in jar-files
                    collect (let ((stdout-str (make-array '(0)
                                                          :element-type
                                                          #+sbcl 'extended-char
                                                          #-sbcl 'character
                                                          :fill-pointer 0
                                                          :adjustable t)))
                                 (with-output-to-string (stdout stdout-str)
                                   (run-program
                                     (format nil
                                             "jar tf ~a/~a | ~
                                              grep -o '[^/]*.class$'"
                                             sandbox jar-file)
                                     :force-shell t
                                     :ignore-error-status t
                                     :output stdout))
                                 (extract-filename-list
                                   (split-sequence
                                     #\Newline
                                     (string-trim '(#\Newline)
                                                  stdout-str))))))))
             (note 3 "~a class files extracted from jars"
                   (list-length class-files))
             class-files)))))

(defun compare-file-lists (jar-files project-files)
  "Compare the lists, returns full path list if filename is in both lists"
  (note 3 "Producing intersection of class files and project files")
  (let ((applicable-project-files
          (loop for path in project-files
                when (find (get-filename path) jar-files :test #'equal)
                collect path)))
       (note 3 "~a applicable files identified from build"
             (list-length applicable-project-files))
       applicable-project-files))


(defun get-applicable-project-files (jar-path project-path)
  "Get list of files that are both in project folder and in jar"
  (compare-file-lists
    (get-files-jar jar-path)
    (get-files-project-folder project-path)))

(defvar *java-project-execution-script-template*
  "#!/bin/bash
echo \"$@\"
java -jar ~a $@"
  "Template for the java execution script to run class files")

(defmethod phenome ((obj java-project) &key (bin (temp-file-name)))
  "Compiles the software object to a jar and converts it to a linux executable"
  (write-genome-to-files obj)
  (note 3 "Compiling project")
  ;; Build the object
  (multiple-value-bind (stdout stderr exit)
      (shell "cd ~a && ~a ~a" *build-dir*
             (build-command obj) (build-target obj))
    (restart-case
        (if (zerop exit)
            (with-temp-file-of (script-file) *java-execution-script-template*
              (shell "cat ~a ~a > ~a && chmod +x ~a"
                     script-file
                     (merge-pathnames-as-file *build-dir*
                                              (build-target obj))
                     bin bin))
            (error (make-condition 'phenome
                     :text stderr :obj obj :loc *build-dir*)))
      (retry-project-build ()
        :report "Retry `phenome' on OBJ."
        (phenome obj :bin bin))
      (return-nil-for-bin ()
        :report "Allow failure returning NIL for bin."
        (setf bin nil)))
    (values bin exit stderr stdout
            (mapcar [#'full-path #'first] (evolve-files obj)))))

(defmethod flags ((obj java-project))
  (declare (ignorable obj))
  nil)

(defmethod clang-format ((java-project java-project) &optional style)
  (declare (ignorable style))
  java-project)

(defmethod indent ((java-project java-project) &optional style)
  (declare (ignorable style))
  java-project)

(defmethod clang-tidy ((java-project java-project))
  java-project)
