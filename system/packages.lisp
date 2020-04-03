;;;; Copyright (c) 2011-2016 Henry Harrington <henry.harrington@gmail.com>
;;;; This code is licensed under the MIT license.

;;;; The CL package system.
;;;; This file must be loaded last during system bootstrapping.

(in-package :mezzano.internals)

(declaim (special *package*))

(defvar *package-system-lock* (mezzano.supervisor:make-mutex '*package-system-lock*))

(defvar *package-list* '()
  "The package registry.")
(defvar *keyword-package* nil
  "The keyword package.")

;; FIXME: This is a recursive mutex because some package functions (eg INTERN)
;; call other package functions (eg FIND-PACKAGE). This needs to be untangled
;; at some point by providing versions of the inner functions that don't
;; take the locks.
(defun call-with-package-system-lock (thunk)
   (if (mezzano.supervisor:mutex-held-p *package-system-lock*)
       (funcall thunk)
       (mezzano.supervisor:without-footholds
         (mezzano.supervisor:with-mutex (*package-system-lock*)
           (handler-bind
               ;; Release the mutex when errors are signalled. This way the
               ;; debugger will run with the lock unheld but restarts will
               ;; properly reacquire it.
               ;; This is required when the debugger may span multiple threads,
               ;; like slime/swank's does.
               ((error (lambda (c)
                         (when (mezzano.supervisor:mutex-held-p *package-system-lock*)
                           (mezzano.supervisor:release-mutex *package-system-lock*)
                           (unwind-protect
                                (mezzano.supervisor:with-local-footholds
                                  (error c))
                             (mezzano.supervisor:acquire-mutex *package-system-lock*))))))
             (funcall thunk))))))

(defmacro with-package-system-lock ((&key) &body body)
  `(call-with-package-system-lock (lambda () ,@body)))

(defun check-package-system-lock-held ()
  (assert (mezzano.supervisor:mutex-held-p *package-system-lock*)))

(defstruct (package
             (:constructor %make-package (%name %nicknames))
             (:predicate packagep))
  %name
  %nicknames
  %use-list
  %used-by-list
  %local-nickname-list
  %locally-nicknamed-by-list
  (%internal-symbols (make-hash-table :test 'equal))
  (%external-symbols (make-hash-table :test 'equal))
  %shadowing-symbols
  documentation)

(defun package-name (package)
  (package-%name (find-package-or-die package)))

(defun package-nicknames (package)
  (package-%nicknames (find-package-or-die package)))

(defun package-use-list (package)
  (package-%use-list (find-package-or-die package)))

(defun package-used-by-list (package)
  (package-%used-by-list (find-package-or-die package)))

(defun package-shadowing-symbols (package)
  (package-%shadowing-symbols (find-package-or-die package)))

(defun list-all-packages ()
  (with-package-system-lock ()
    (remove-duplicates (mapcar 'cdr *package-list*))))

(defmacro in-package (name)
  `(eval-when (:compile-toplevel :load-toplevel :execute)
     (setq *package* (find-package-or-die ',name))))

(deftype package-designator ()
  `(or package (and string-designator (satisfies package-designator-p))))

(defun package-designator-p (object)
  (or (packagep object)
      (and (typep object 'string-designator)
           (find-package object))))

(defun find-global-package (name)
  (check-type name (or package string-designator))
  (if (packagep name)
      name
      (with-package-system-lock ()
        (cdr (assoc (string name) *package-list* :test 'string=)))))

(defun find-global-package-or-die (name)
  (or (find-global-package name)
      (error 'unknown-package-error
             :package name
             :datum name
             :expected-type 'package-designator)))

(defun find-package (name)
  (check-type name (or package string-designator))
  (cond ((packagep name)
         name)
        ((not (and (boundp '*package*)
                   (packagep *package*)))
         (find-global-package name))
        (t
         ;; Search local nicknames, then fall back on the global namespace.
         (with-package-system-lock ()
           (loop
              for (local-nickname . actual-package) in (package-local-nicknames *package*)
              when (string= local-nickname name)
              return actual-package
              finally (return (find-global-package name)))))))

(defun find-package-or-die (name)
  (or (find-package name)
      (error 'unknown-package-error
             :package name
             :datum name
             :expected-type 'package-designator)))

(defun use-one-package (package-to-use package)
  (check-package-system-lock-held)
  (when (eql package-to-use *keyword-package*)
    (error 'simple-package-error
           :package package
           :format-control "Cannot use the KEYWORD package."
           :format-arguments '()))
  (pushnew package-to-use (package-%use-list package))
  (pushnew package (package-%used-by-list package-to-use)))

(defun use-package (packages-to-use &optional (package *package*))
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (if (listp packages-to-use)
          (dolist (use-package packages-to-use)
            (use-one-package (find-package-or-die use-package) p))
          (use-one-package (find-package-or-die packages-to-use) p))))
  t)

(defun unuse-one-package (package-to-unuse package)
  (check-package-system-lock-held)
  (setf (package-%use-list package)
        (remove package-to-unuse (package-%use-list package)))
  (setf (package-%used-by-list package-to-unuse)
        (remove package (package-%used-by-list package-to-unuse))))

(defun unuse-package (packages-to-unuse &optional (package *package*))
  (with-package-system-lock ()
    (let ((package (find-package-or-die package)))
      (if (listp packages-to-unuse)
          (dolist (unuse-package packages-to-unuse)
            (unuse-one-package (find-package-or-die unuse-package) package))
          (unuse-one-package (find-package-or-die packages-to-unuse) package))))
  t)

(defun make-package (package-name &key nicknames use)
  (with-package-system-lock ()
    (when (find-global-package package-name)
      (error 'simple-package-error
             :package package-name
             :format-control "A package named ~S already exists."
             :format-arguments (list package-name)))
    (dolist (n nicknames)
      (when (find-global-package n)
        (error 'simple-package-error
               :package n
               :format-control "A package named ~S already exists."
               :format-arguments (list n))))
    (let ((use-list (mapcar 'find-package use))
          (package (%make-package (string package-name)
                                  (mapcar (lambda (x) (string x)) nicknames))))
      ;; Use packages.
      (use-package use-list package)
      ;; Install the package in the package registry.
      (push (cons (package-name package) package) *package-list*)
      (dolist (s (package-nicknames package))
        (push (cons s package) *package-list*))
      package)))

(defun find-symbol (string &optional (package *package*))
  (check-type string string)
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (multiple-value-bind (sym present-p)
          (gethash string (package-%internal-symbols p))
        (when present-p
          (return-from find-symbol (values sym :internal))))
      (multiple-value-bind (sym present-p)
          (gethash string (package-%external-symbols p))
        (when present-p
          (return-from find-symbol (values sym :external))))
      (let ((pending (remove-duplicates (package-use-list p)))
            (visited '()))
        (loop
           (when (endp pending)
             (return (values nil nil)))
           (let ((pak (pop pending)))
             (when (not (member pak visited))
               (push pak visited)
               (multiple-value-bind (sym present-p)
                   (gethash string (package-%external-symbols pak))
                 (when present-p
                   (return (values sym :inherited))))
               (dolist (subpak (package-use-list pak))
                 (pushnew subpak pending)))))))))

(defun import-one-symbol (symbol package)
  (check-package-system-lock-held)
  ;; Check for a conflicting symbol.
  (multiple-value-bind (existing-symbol existing-mode)
      (find-symbol (symbol-name symbol) package)
    (when (and existing-mode
               (not (eq existing-symbol symbol)))
      (ecase existing-mode
        (:inherited
         (restart-case
             (error 'simple-package-error
                    :format-control "Newly imported symbol ~S conflicts with inherited symbol ~S."
                    :format-arguments (list symbol existing-symbol))
           (shadow-symbol ()
             :report "Replace the inherited symbol."
             (shadow (list symbol) package))
           (dont-import ()
             :report "Leave the existing inherited symbol."
             (return-from import-one-symbol))))
        ((:internal :external)
         (restart-case
             (error 'simple-package-error
                    :package package
                    :format-control "Newly imported symbol ~S conflicts with present symbol ~S."
                    :format-arguments (list symbol existing-symbol))
           (unintern-old-symbol ()
             :report "Unintern and replace the old symbol."
             (unintern symbol package))
           (dont-import ()
             :report "Leave the existing inherited symbol."
             (return-from import-one-symbol))))))
    (multiple-value-bind (existing-external-symbol external-symbol-presentp)
        (gethash (symbol-name symbol) (package-%external-symbols package))
      (unless (and external-symbol-presentp
                   (eql symbol existing-external-symbol))
        (multiple-value-bind (existing-internal-symbol internal-symbol-presentp)
            (gethash (symbol-name symbol) (package-%internal-symbols package))
          (unless (and internal-symbol-presentp
                       (eql symbol existing-internal-symbol))
            (setf (gethash (symbol-name symbol) (package-%internal-symbols package)) symbol)))))
    (unless (symbol-package symbol)
      (setf (symbol-package symbol) package))))

(defun import (symbols &optional (package *package*))
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (if (listp symbols)
          (dolist (s symbols)
            (import-one-symbol s p))
          (import-one-symbol symbols p))))
  t)

(defun export-one-symbol (symbol package)
  (check-package-system-lock-held)
  (dolist (q (package-used-by-list package))
    (multiple-value-bind (other-symbol status)
        (find-symbol (symbol-name symbol) q)
      (when (and (not (eq symbol other-symbol))
                 status
                 (not (member other-symbol (package-%shadowing-symbols q))))
        (restart-case
            (error 'simple-package-error
                   :package package
                   :format-control "Newly exported symbol ~S conflicts with symbol ~S in package ~S."
                   :format-arguments (list symbol other-symbol q))
          (shadow-symbol ()
            :report "Leave the existing symbol as shadowing symbol."
            (shadow (list other-symbol) q))
          (unintern-symbol ()
            ;; What is this supposed to do in the inherited case?
            ;; SBCL seems to leave the existing symbol accessible.
            :report "Unintern the existing symbol, replacing it."
            (unintern other-symbol q))))))
  (import-one-symbol symbol package)
  ;; Remove from the internal-symbols list.
  (remhash (symbol-name symbol) (package-%internal-symbols package))
  ;; And add to the external-symbols list.
  (setf (gethash (symbol-name symbol) (package-%external-symbols package)) symbol))

(defun export (symbols &optional (package *package*))
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (if (listp symbols)
          (dolist (s symbols)
            (export-one-symbol s p))
          (export-one-symbol symbols p))))
  t)

(defun unexport-one-symbol (symbol package)
  (check-package-system-lock-held)
  (let* ((name (symbol-name symbol)))
    (multiple-value-bind (sym mode)
        (find-symbol name package)
      (declare (ignore sym))
      (case mode
        (:external
         ;; Remove the symbol from the external symbols
         (remhash name (package-%external-symbols package))
         ;; And add to the internal-symbols list.
         (setf (gethash name (package-%internal-symbols package)) symbol))
        ((:internal :inherited))
        (t
         (error 'simple-package-error
                :package package
                :format-control "Cannot unexport unaccessable symbol ~S for package ~S."
                :format-arguments (list symbol package))))))
  t)

(defun unexport (symbols &optional (package *package*))
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (if (listp symbols)
          (dolist (s symbols)
            (unexport-one-symbol s p))
          (unexport-one-symbol symbols p))))
  t)

(defun unintern (symbol &optional (package *package*))
  (check-type symbol symbol)
  (with-package-system-lock ()
    (setf package (find-package-or-die package))
    (when (eql (symbol-package symbol) package)
      (setf (symbol-package symbol) nil))
    (let ((removed-symbol-p nil))
      (multiple-value-bind (existing-internal-symbol internal-symbol-presentp)
          (gethash (symbol-name symbol) (package-%internal-symbols package))
        (when (and internal-symbol-presentp (eql existing-internal-symbol symbol))
          (setf removed-symbol-p t)
          (remhash (symbol-name symbol) (package-%internal-symbols package))))
      (multiple-value-bind (existing-external-symbol external-symbol-presentp)
          (gethash (symbol-name symbol) (package-%external-symbols package))
        (when (and external-symbol-presentp (eql existing-external-symbol symbol))
          (setf removed-symbol-p t)
          (remhash (symbol-name symbol) (package-%external-symbols package))))
      (setf (package-%shadowing-symbols package) (remove symbol (package-%shadowing-symbols package)))
      removed-symbol-p)))

(defun make-package-iterator-find-symbols (package symbol-types)
  "Find all the symbols in PACKAGE that match SYMBOL-TYPES."
  (with-package-system-lock ()
    (let ((symbols '()))
      (when (member :internal symbol-types)
        (maphash (lambda (k v)
                   (declare (ignore k))
                   (push (cons v :internal) symbols))
                 (package-%internal-symbols package)))
      (when (member :external symbol-types)
        (maphash (lambda (k v)
                   (declare (ignore k))
                   (push (cons v :external) symbols))
                 (package-%external-symbols package)))
      (when (member :inherited symbol-types)
        (dolist (p (package-use-list package))
          (maphash (lambda (k v)
                     (declare (ignore k))
                     (push (cons v :inherited) symbols))
                   (package-%external-symbols p))))
      symbols)))

(defun make-package-iterator (package-list symbol-types)
  ;; Listify PACKAGE-LIST.
  (unless (listp package-list)
    (setf package-list (list package-list)))
  ;; Convert package designators to packages.
  (setf package-list (mapcar #'find-package-or-die package-list))
  (let ((symbols nil)
        (current-package nil))
    (lambda ()
      (declare (lambda-name w-p-i-iterator))
      (when (endp symbols)
        ;; Find a package with symbols that match.
        (loop
           (when (endp package-list) (return))
           (setf current-package (pop package-list))
           (setf symbols (make-package-iterator-find-symbols current-package symbol-types))
           (when symbols (return))))
      (when symbols
        (let ((symbol (pop symbols)))
          (values t
                  (car symbol)
                  (cdr symbol)
                  current-package))))))

(defun package-iterator-next (iterator)
  (funcall iterator))

(defmacro with-package-iterator ((name package-list-form &rest symbol-types) &body body)
  (when (endp symbol-types)
    (error 'simple-program-error
           :format-control "No symbol types specified"
           :format-arguments '()))
  (dolist (symbol-type symbol-types)
    (when (not (member symbol-type '(:internal :external :inherited)))
      (error 'simple-program-error
           :format-control "Unknown symbol type ~S"
           :format-arguments (list symbol-type))))
  (let ((iterator (gensym "PACKAGE-ITERATOR")))
    `(let ((,iterator (make-package-iterator ,package-list-form ',symbol-types)))
       (macrolet ((,name ()
                    `(package-iterator-next ,',iterator)))
         ,@body))))

(defun map-symbols (fn package)
  (with-package-iterator (itr (list package) :internal :external :inherited)
    (loop (multiple-value-bind (valid symbol)
              (itr)
            (when (not valid) (return))
            (funcall fn symbol)))))

(defmacro do-symbols ((var &optional (package '*package*) result-form) &body body)
  (multiple-value-bind (body-forms declares)
      (parse-declares body)
    `(block nil
       (map-symbols (lambda (,var)
                      (declare ,@declares)
                      (tagbody ,@body-forms))
                    ,package)
       (let ((,var nil))
         (declare (ignorable ,var)
                  ,@declares)
         ,result-form))))

(defun map-external-symbols (fn package)
  (with-package-iterator (itr (list package) :external)
    (loop (multiple-value-bind (valid symbol)
              (itr)
            (when (not valid) (return))
            (funcall fn symbol)))))

(defmacro do-external-symbols ((var &optional (package '*package*) result-form) &body body)
  (multiple-value-bind (body-forms declares)
      (parse-declares body)
    `(block nil
       (map-external-symbols (lambda (,var)
                               (declare ,@declares)
                               (tagbody ,@body-forms))
                             ,package)
       (let ((,var nil))
         (declare (ignorable ,var)
                  ,@declares)
         ,result-form))))

(defun map-all-symbols (fn)
  (with-package-iterator (itr (list-all-packages) :internal :external)
    (loop (multiple-value-bind (valid symbol)
              (itr)
            (when (not valid) (return))
            (funcall fn symbol)))))

(defmacro do-all-symbols ((var &optional result-form) &body body)
  (multiple-value-bind (body-forms declares)
      (parse-declares body)
    `(block nil
       (map-all-symbols (lambda (,var)
                          (declare ,@declares)
                          (tagbody ,@body-forms)))
       (let ((,var nil))
         (declare (ignorable ,var)
                  ,@declares)
         ,result-form))))

(defun find-all-symbols (string)
  (setf string (string string))
  (with-package-system-lock ()
    (let ((symbols '()))
      (dolist (p (list-all-packages))
        (multiple-value-bind (sym foundp)
            (gethash string (package-%internal-symbols p))
          (when foundp
            (pushnew sym symbols)))
        (multiple-value-bind (sym foundp)
            (gethash string (package-%external-symbols p))
          (when foundp
            (pushnew sym symbols))))
      symbols)))

(defun intern (name &optional (package *package*))
  (with-package-system-lock ()
    (assert *package-list* () "Package system not initialized?")
    (let ((p (find-package-or-die package)))
      (multiple-value-bind (symbol status)
          (find-symbol name p)
        (when status
          (return-from intern (values symbol status))))
      (let ((symbol (make-symbol name)))
        (import (list symbol) p)
        (when (eql p *keyword-package*)
          (setf (symbol-mode symbol) :special)
          (setf (symbol-value symbol) symbol)
          (setf (symbol-mode symbol) :constant)
          (export (list symbol) p))
        (values symbol nil)))))

(defun delete-package (package)
  (when (and (packagep package)
             (not (package-%name package)))
    (return-from delete-package nil))
  (with-package-system-lock ()
    (let ((p (find-package-or-die package)))
      (when (package-used-by-list p)
        (error 'simple-package-error
               :package package
               :format-control "Package ~S is in use."
               :format-arguments (list package)))
      ;; Remove the package from the use list.
      (dolist (other (package-use-list p))
        (setf (package-%used-by-list other) (remove p (package-used-by-list other))))
      ;; Remove all symbols.
      (maphash (lambda (name symbol)
                 (declare (ignore name))
                 (when (eq (symbol-package symbol) package)
                   (setf (symbol-package symbol) nil)))
               (package-%internal-symbols p))
      (maphash (lambda (name symbol)
                 (declare (ignore name))
                 (when (eq (symbol-package symbol) package)
                   (setf (symbol-package symbol) nil)))
               (package-%external-symbols p))
      (setf (package-%name p) nil
            (package-%nicknames p) '())
      (setf *package-list* (remove p *package-list* :key 'cdr))
      t)))

(defun keywordp (object)
  (and (symbolp object)
       (eq (symbol-package object) *keyword-package*)))

(defun %defpackage (name &key
                           nicknames
                           documentation
                           ((:uses use-list))
                           ((:imports import-list))
                           ((:exports export-list))
                           ((:interns intern-list))
                           ((:shadows shadow-list))
                           ((:shadowing-imports shadow-import-list))
                           local-nicknames)
  (with-package-system-lock ()
    (let ((p (find-global-package name)))
      (cond (p ;; Add nicknames.
             (dolist (n nicknames)
               (when (and (find-global-package n)
                          (not (eql (find-global-package n) p)))
                 (error 'simple-package-error
                        :package p
                        :format-control "A package named ~S already exists."
                        :format-arguments (list n))))
             (dolist (n nicknames)
               (pushnew (cons n p) *package-list* :test #'equal)))
            (t (setf p (make-package name :nicknames nicknames))))
      (when documentation
        (setf (package-documentation p) documentation))
      (dolist (s shadow-list)
        (shadow-one-symbol (string s) p))
      (shadowing-import shadow-import-list p)
      (use-package use-list p)
      (import import-list p)
      (dolist (s intern-list)
        (intern (string s) p))
      (dolist (s export-list)
        (export-one-symbol (intern (string s) p) p))
      (dolist (package-nickname-pair local-nicknames)
        (destructuring-bind (local-nickname actual-package)
            package-nickname-pair
          (add-package-local-nickname local-nickname actual-package p)))
      p)))

(defmacro defpackage (defined-package-name &rest options)
  (let ((nicknames '())
        (documentation nil)
        (use-list '())
        (import-list '())
        (export-list '())
        (intern-list '())
        (shadow-list '())
        (shadow-import-list '())
        (local-nicknames '())
        (size nil))
    (dolist (o options)
      (ecase (first o)
        (:nicknames
         (dolist (n (rest o))
           (pushnew (string n) nicknames)))
        (:documentation
         (when documentation
           (error 'simple-program-error
                  :format-control "Multiple documentation options in DEFPACKAGE form."
                  :format-arguments '()))
         (unless (or (eql 2 (length o))
                     (not (stringp (second o))))
           (error 'simple-program-error
                  :format-control "Invalid documentation option in DEFPACKAGE form."
                  :format-arguments '()))
         (setf documentation (second o)))
        (:use
         (dolist (u (rest o))
           (if (packagep u)
               (pushnew u use-list)
               (pushnew (string u) use-list))))
        (:import-from
         (let ((package (find-package-or-die (second o))))
           (dolist (name (cddr o))
             (multiple-value-bind (symbol status)
                 (find-symbol (string name) package)
               (unless status
                 (error "No such symbol ~S in package ~S." (string name) package))
               (pushnew symbol import-list)))))
        (:export
         (dolist (name (cdr o))
           (pushnew name export-list)))
        (:intern
         (dolist (name (cdr o))
           (pushnew name intern-list)))
        (:shadow
         (dolist (name (cdr o))
           (pushnew name shadow-list)))
        (:shadowing-import-from
         (let ((package (find-package-or-die (second o))))
           (dolist (name (cddr o))
             (multiple-value-bind (symbol status)
                 (find-symbol (string name) package)
               (unless status
                 (error "No such symbol ~S in package ~S." (string name) package))
               (pushnew symbol shadow-import-list)))))
        (:size
         (when size
           (error 'simple-program-error
                  :format-control "Multiple size options in DEFPACKAGE form."
                  :format-arguments '()))
         (unless (or (eql 2 (length o))
                     (not (integerp (second o))))
           (error 'simple-program-error
                  :format-control "Invalid size option in DEFPACKAGE form."
                  :format-arguments '()))
         (setf size (second o)))
        (:local-nicknames
         (setf local-nicknames (append local-nicknames (rest o))))))
    `(eval-when (:compile-toplevel :load-toplevel :execute)
       (%defpackage ,(string defined-package-name)
                    :nicknames ',nicknames
                    :documentation ',documentation
                    :uses ',use-list
                    :imports ',import-list
                    :exports ',export-list
                    :interns ',intern-list
                    :shadows ',shadow-list
                    :shadowing-imports ',shadow-import-list
                    :local-nicknames ',local-nicknames))))

(defun rename-package (package new-name &optional new-nicknames)
  (with-package-system-lock ()
    (setf package (find-package-or-die package))
    (when (packagep new-name)
      (error "Not sure what to do when NEW-NAME is a package?"))
    (setf new-name (string new-name))
    (setf new-nicknames (mapcar 'string new-nicknames))
    (let ((new-names (remove-duplicates (cons new-name new-nicknames)))
          (old-names (cons (package-name package) (package-nicknames package))))
      (dolist (name new-names)
        (when (and (find-package name)
                   (not (eql (find-package name) package)))
          (error "New name ~S for package ~S conflicts with existing package ~S.~%"
                 name package (find-package name))))
      ;; Remove the old names.
      (setf *package-list* (remove-if (lambda (name)
                                        (member name old-names :test 'string=))
                                      *package-list*
                                      :key 'car))
      ;; Add the new names.
      (dolist (name new-names)
        (push (cons name package) *package-list*))
      ;; Rename the package
      (setf (package-%name package) new-name
            (package-%nicknames package) new-nicknames))
    package))

(defun shadow-one-symbol (symbol-name package)
  (check-package-system-lock-held)
  (multiple-value-bind (symbol presentp)
      (gethash symbol-name (package-%internal-symbols package))
    (declare (ignore symbol))
    (when presentp (return-from shadow-one-symbol)))
  (multiple-value-bind (symbol presentp)
      (gethash symbol-name (package-%external-symbols package))
    (declare (ignore symbol))
    (when presentp (return-from shadow-one-symbol)))
  (let ((new-symbol (make-symbol symbol-name)))
    (push new-symbol (package-%shadowing-symbols package))
    (setf (symbol-package new-symbol) package
          (gethash symbol-name (package-%internal-symbols package)) new-symbol)))

(defun shadowing-import (symbols &optional (package *package*))
  (with-package-system-lock ()
    (when (not (listp symbols))
      (setf symbols (list symbols)))
    (setf package (find-package-or-die package))
    (dolist (symbol symbols)
      (check-type symbol symbol)
      (pushnew symbol (package-%shadowing-symbols package)))
    (import symbols package)))

(defun shadow (symbol-names &optional (package *package*))
  (with-package-system-lock ()
    (unless (listp symbol-names)
      (setf symbol-names (list symbol-names)))
    (setf package (find-package-or-die package))
    (dolist (symbol symbol-names)
      (shadow-one-symbol (string symbol) package)))
  t)

(defun package-shortest-name (package)
  (let ((name (package-name package)))
    (dolist (nick (package-nicknames package))
      (when (< (length nick) (length name))
        (setf name nick)))
    name))

(defun package-local-nicknames (package)
  (package-%local-nickname-list (find-package-or-die package)))

(defun package-locally-nicknamed-by-list (package)
  (package-%locally-nicknamed-by-list (find-package-or-die package)))

(defun add-package-local-nickname (local-nickname actual-package &optional (package *package*))
  (with-package-system-lock ()
    (let ((local-nickname (string local-nickname))
          (actual-package (find-global-package-or-die actual-package)))
      (when (member local-nickname '("CL" "COMMON-LISP" "KEYWORD") :test #'string=)
        (error "New package local nickname ~S conflicts with standard CL package." local-nickname))
      (let ((existing (assoc local-nickname (package-local-nicknames package) :test #'string=)))
        (cond ((not existing)
               (push (cons local-nickname actual-package) (package-%local-nickname-list package))
               (pushnew package (package-%locally-nicknamed-by-list actual-package)))
              ((not (eql actual-package (cdr existing)))
               (cerror "Replace it" "New local nickname ~S for package ~S conflicts with existing nickname for package ~S."
                       local-nickname actual-package (cdr existing))
               (remove-package-local-nickname local-nickname package)
               (push (cons local-nickname actual-package) (package-%local-nickname-list package))
               (pushnew package (package-%locally-nicknamed-by-list actual-package)))))))
  package)

(defun remove-package-local-nickname (local-nickname &optional (package *package*))
  (with-package-system-lock ()
    (let* ((existing (assoc local-nickname (package-%local-nickname-list package) :test #'string=)))
      (when existing
        (let ((other-package (cdr existing)))
          (setf (package-%local-nickname-list package) (remove local-nickname (package-%local-nickname-list package)
                                                               :test #'string= :key #'car))
          (when (zerop (count other-package (package-%local-nickname-list package)
                              :key #'cdr))
            (setf (package-%locally-nicknamed-by-list other-package) (remove package (package-%locally-nicknamed-by-list other-package)))))
        t))))

(defun initialize-package-system ()
  (write-line "Initializing package system.")
  (with-package-system-lock ()
    ;; Create the core packages.
    (setf *package-list* '())
    (setf *keyword-package* (make-package "KEYWORD"))
    (make-package "COMMON-LISP" :nicknames '("CL"))
    (make-package "COMMON-LISP-USER" :nicknames '("CL-USER") :use '("CL"))
    (setf *package* (make-package "MEZZANO.INTERNALS" :use '("CL")))
    ;; Now import all the symbols.
    (dotimes (i (length *initial-obarray*))
      (let ((sym (aref *initial-obarray* i)))
        (let* ((package-keyword (symbol-package sym))
               (package (find-package (string package-keyword))))
          (when (not package)
            (setf package (make-package (string package-keyword) :use '("CL"))))
          (setf (symbol-package sym) nil)
          (import-one-symbol sym package)
          (when (member package-keyword '(:common-lisp :keyword))
            (export-one-symbol sym package))))))
  (values))
