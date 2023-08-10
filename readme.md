# elhive

Declarative process management for Emacs.

This is a work in progress package which I use while doing literate programming and
journaling my work & research. So API does not contain any interactive functions.

/I have no plans to publish this on MELPA at the moment (but may do this in future)./

# example

Literal example using Emacs Lisp:

```lisp
(defelhive-group core
  (postgresql :directory ".postgres"
	      :command "bash"
	      :arguments `("-exc" ,(string-join
				    '("[ -d data ] || pg_ctl initdb --pgdata=data"
				      "postgres -D data -k .")
				    "\n")))
  (kafka :directory ".kafka"
	 :command "bash"
	 :arguments `("-exc"
		      ,(string-join
			'("cat <<EOF > kafka.properties"
			  "process.roles=broker,controller"
			  "node.id=1"
			  "broker.id=1"
			  "listeners=PLAINTEXT://:9092,CONTROLLER://:9093"
			  "controller.quorum.voters=1@localhost:9093"
			  "controller.listener.names=CONTROLLER"
			  "offsets.topic.replication.factor=1"
			  "transaction.state.log.replication.factor=1"
			  "transaction.state.log.min.isr=1"
			  "log.dirs=kafka"
			  "EOF"
			  "kafka-storage.sh format -t $KAFKA_CLUSTER_ID -c kafka.properties --ignore-formatted"
			  "kafka-server-start.sh kafka.properties")
			"\n"))
	 :environment '((KAFKA_CLUSTER_ID "2psaV9dFRpagmluSBIlHKg"))))

(elhive-group-start 'core)
(elhive-state)
;; =>
;; ((core
;;   (("postgresql" . inactive)
;;    ("kafka" . inactive)
;;    ("am-server" . inactive))))

(elhive-group-stop 'core)
```

Example of using with org-mode:

```org
#+constants: postgres=~/projects/src/git.backbone/.postgres
#+constants: kafka=~/projects/src/git.backbone/.kafka

#+begin_src elisp :results output
(defelhive-group core
  (postgresql :directory (org-table-get-constant "postgres")
	      :command "bash"
	      :arguments `("-exc" ,(string-join
				    '("[ -d data ] || pg_ctl initdb --pgdata=data"
				      "postgres -D data -k .")
				    "\n")))
  (kafka :directory (org-table-get-constant "kafka")
	 :command "bash"
	 :arguments `("-exc"
		      ,(string-join
			'("cat <<EOF > kafka.properties"
			  "process.roles=broker,controller"
			  "node.id=1"
			  "broker.id=1"
			  "listeners=PLAINTEXT://:9092,CONTROLLER://:9093"
			  "controller.quorum.voters=1@localhost:9093"
			  "controller.listener.names=CONTROLLER"
			  "offsets.topic.replication.factor=1"
			  "transaction.state.log.replication.factor=1"
			  "transaction.state.log.min.isr=1"
			  "log.dirs=kafka"
			  "EOF"
			  "kafka-storage.sh format -t $KAFKA_CLUSTER_ID -c kafka.properties --ignore-formatted"
			  "kafka-server-start.sh kafka.properties")
			"\n"))
	 :environment '((KAFKA_CLUSTER_ID "2psaV9dFRpagmluSBIlHKg"))))
#+end_src

#+RESULTS:


#+begin_src elisp :results output
(elhive-group-restart 'core)
#+end_src

#+RESULTS:

#+begin_src elisp :results value pp
(elhive-state)
#+end_src

#+RESULTS:
: ((core
:   (("postgresql" . inactive)
:    ("kafka" . inactive))

#+begin_src elisp :results output
(elhive-group-stop 'core)
#+end_src

#+RESULTS:
```
