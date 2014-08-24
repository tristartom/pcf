;;; this iterates through a control-flow graph to perform faint-variable analysis. it is adapted from Data Flow Analysis: Theory and Practice by Khedker, Sanyal, and Karkare
;;; author: bt3ze@virginia.edu
(defpackage :pcf2-faintgate
  (:use :common-lisp :pcf2-bc :setmap :utils :pcf2-dataflow)
  ;;(:export faint-analysis-flow)
  )

(in-package :pcf2-faintgate)

;; this analysis tracks the uses of wires through a program to determine which are actually useful to the output and which are merely dead weight
;; we do this by tracing wire values backwards from their outputs with output_alice and output_bob to their initialization. wires that do not contribute to the output may be discarded
;;; definition: A variable x e Var is _faint_ at a program point *u* if along every path from u to End, it is neither not used before being defined or is used to define a faint variable (this is the complement of liveness)

;;; f_n(x) = (x-Kill_n(x) Union Gen_n

;;; Faint variable analysis is a backwards data flow problem
;;; since it is an all-paths analysis, the confluence operator is Intersection
;;; and since the most aggressive optimization is to declare all variables faint, the "top" value is Var (or all variables)

;;; Gen_n(x) = ConstGen_n Union DepGen_n(x)
;;; Kill_n(x) = ConstKill_n Union DepKill_n(x)

;;; in general, Gen and Kill for faint variable analysis are:
;;;
;;; In_n = F_n(Out_n)
;;; Out_n = { BI   n is end
;;;           Meet (s in succ(n) In_s)  Otherwise
;;; (remember, In_s is passed to the next block, Out_n is an input to this block)

;;; ConstGen_n = { {x} n is assignment x=e, x /e Opd(e) 
;;;                {x} n is read(x) ;; read is always alice() or bob()
;;;                /0  otw
;;; DepGen_n(x) = /0
;;;
;;; explanation: variables become faint before every assignment to them (because this is a backwards flow, this is like saying that a variable becomes faint when it will be redefined before its next use)

;;; ConstKill_n    = { {x}  n is use(x) ;; here, out use(x) comes in output_alice and output_bob, or 
;;;                    /0   otw
;;; DepKill_n(x)   = { Opd(e) Intersect Var   n is assignment x=e, x/e *x*
;;;                     /0                otw
;;; explanation: x is not faint if it is used towards the output of the program
;;; DepKill simply states that all of the operands of the expression which are variables hit the kill list; if a variable appears on both the lhs and rhs of an assignment, it does not become faint before the assignment, since that value is still important to the output

(defparameter confluence-operator #'set-inter)
;; "top" is Var

(defmacro top-set ()
  `(set-insert (empty-set) "top"))

(defun confluence-op (set1 set2)
  ;; if either set is "top," return the other set
  (cond
    ((set-equalp set1 (top-set)) set2)
    ((set-equalp set2 (top-set)) set1)
    (t 
     (funcall confluence-operator set1 set2))))

(defun get-out-sets (blck cfg)
  (reduce
   (lambda (temp-out succ)
     (let ((succ-out (get-block-out-set (get-block-by-id succ cfg))))
       (funcall #'confluence-op temp-out succ-out)))
   (get-block-succs blck)
   :initial-value (get-block-out-set (get-block-by-id blck cfg))))

(defgeneric faint-flow-fn (blck cfg)
  (:documentation "this function describes how an operation performs its flow function")
  )

(defmethod faint-flow-fn (blck cfg)
  (set-union
   (set-diff (get-out-sets blck cfg) (kill (get-block-op blck)))
   (gen (get-block-op blck))))

(defgeneric gen (op)
  (:documentation "this function describes how to compute the gen part of the flow function for each op") 
  )

(defgeneric kill (op)
  (:documentation "this function describes how to compute the kill part of the flow function for each op")
)

(defgeneric const-gen (op)
  (:documentation "this function describes how to compute the constant gen part of the flow function for each op")
)

(defgeneric dep-gen (op)
  (:documentation "this function describes how to compute the dependent gen part of the flow function for each op")
)

(defgeneric const-kill (op)
  (:documentation "this function describes how to compute the constant kill part of the flow function for each op")
)

(defgeneric dep-kill (op)
  (:documentation "this function describes how to compute the dependent kill part of the flow function for each op")
)

(defmethod gen (op)
  ;; gen = const_gen union dep_gen
  (set-union (const-gen op) (dep-gen op)))

(defmethod kill (op)
  ;; kill = const-kill union gep_kill
  (set-union (const-kill op) (dep-kill op)))

(defmacro gen-kill-standard ()
  ;; for faint variable analysis, standard is always empty set
  `(empty-set))

;;; macros to define const-gen, dep-gen, const-kill, and dep-kill

(defmacro def-const-gen (type &body body)
  `(defmethod const-gen ((op ,type))
     (declare (optimize (debug 3) (speed 0)))
     (aif (locally ,@body)
          it
          (gen-kill-standard)
          )))

(defmacro def-dep-gen (type &body body)
  `(defmethod dep-gen ((op ,type) blck)
     (declare (optimize (debug 3) (speed 0)))
     (aif (locally ,@body)
          it
          (gen-kill-standard)
          )))

(defmacro def-const-kill (type &body body)
  `(defmethod const-kill ((op ,type))
     (declare (optimize (debug 3) (speed 0)))
     (aif (locally ,@body)
          it
          (gen-kill-standard)
          )))

(defmacro def-dep-kill (type &body body)
  `(defmethod dep-kill ((op ,type))
     (declare (optimize (debug 3) (speed 0)))
     (aif (locally ,@body)
          it
          (gen-kill-standard)
          )))

;; and the macro to write const-gen, dep-gen, const-kill, and dep-kill for each instruction
(defmacro def-gen-kill (type &key (const-gen nil) (dep-gen nil) (const-kill nil) (dep-kill nil))
  `(def-const-gen ,type ,const-gen)
  `(def-dep-gen ,type ,dep-gen) ; dep-gen always /0 in faint analysis
  `(def-const-kill ,type ,const-kill)
  `(def-dep-kill ,type ,dep-kill)
  )


(def-gen-kill bits
    :const-gen `(with-slots (dest) op
                  (set-from-list dest)) ;; everything in the list gets added to gen
    :const-kill `(with-slots (op1) op
                   (singleton op1)) ;; op1 is not faint
    )

(def-gen-kill join
    :const-gen `(with-slots (op1) op
                  (singleton op1)
                  )
    :const-kill `(with-slots (dest) op
                   (set-from-list dest)
                   )
  )

(def-gen-kill gate
    )

(def-gen-kill const
    ;; if x = const, add x to gen
    :const-gen `(with-slots (dest) op
                  (singleton dest)
                  )
    )

(def-gen-kill add)
(def-gen-kill sub)
(def-gen-kill mul)
(def-gen-kill initbase
    ;; nothing
    )
(def-gen-kill clear
    ;; nothing
    )

(def-gen-kill copy
    :const-gen`(with-slots (op1 op2) op
                 (set-from-list
                  (loop for i from op1 to (+ op1 op2) collect i)
                  ))
    )

(def-gen-kill mkptr)
(def-gen-kill copy-indir)
(def-gen-kill indir-copy)
(def-gen-kill call)
(def-gen-kill ret)
(def-gen-kill branch)
(def-gen-kill label)
