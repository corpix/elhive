;;; elhive.el --- operate on services with emacs -*- lexical-binding: t -*-

;; Copyright (C) 2023 Dmitry Moscowski, corpix.dev

;; Author: Dmitry Moskowski <me@corpix.dev>
;; Keywords: Processes, Services

;;; Code:
(require 'ansi-color)
(require 'subr-x)
(require 'comint)

(defgroup elhive nil
  "Elhive service manager."
  :group 'services
  :group 'unix
  :prefix "elhive-")

(defcustom elhive-ansi-colors-filter t
  "Wether to expand ANSI color key codes in services output."
  :type 'boolean)

;;

(defun elhive--set-process-filters (process)
  (prog1 process
    (when elhive-ansi-colors-filter
      (set-process-filter
       process
       (lambda (process string)
	 ;;(internal-default-process-filter process string)
	 (with-current-buffer (process-buffer process)
	   (goto-char (point-max))
	   (let ((previous-point-max (point-max)))
	     (insert string)
	     (ansi-color-apply-on-region previous-point-max (point-max))
	     (goto-char (point-max)))))))))

;;

(defvar elhive-group 'default)
(defvar elhive-buffer-name-prefix "elhive")

(defvar elhive--services (make-hash-table :test 'equal))
(defvar elhive--services-by-group (make-hash-table :test 'equal))
(defvar elhive--service-instances (make-hash-table :test 'equal))
(defvar elhive--buffer-process nil)

;;

(defmacro defelhive-service (name &rest body)
  (declare (indent defun))
  (progn
    (unless (plist-get body :command)
      (error "Required keyword :command is not defined"))
    (let ((service-sym (gensym))
	  (service-id-sym (gensym))
	  (group-id-sym (gensym))
	  (group-bucket-sym (gensym)))
      `(let* ((,service-sym (elhive--service-defaults ',name (list ,@body)))
	      (,service-id-sym (elhive--service-id ,service-sym)))
	 (prog1 ,service-sym
	   (puthash ,service-id-sym ,service-sym elhive--services)
	   (let* ((,group-id-sym (elhive--service-group ,service-sym))
		  (,group-bucket-sym (or (gethash ,group-id-sym elhive--services-by-group)
					 (make-hash-table :test 'equal))))
	     (puthash ,service-id-sym ,service-sym ,group-bucket-sym)
	     (puthash ,group-id-sym ,group-bucket-sym elhive--services-by-group)))))))

(defmacro defelhive-group (name &rest body)
  (declare (indent defun))
  `(let ((elhive-group ',name))
     (puthash elhive-group (make-hash-table :test 'equal) elhive--services-by-group)
     ,@(mapcar (lambda (service)
		 `(defelhive-service ,@service))
	       body)))

(defmacro with-elhive-service-instance-buffer (instance &rest body)
  (declare (indent defun))
  (let ((buffer-sym (gensym)))
    `(let ((,buffer-sym (elhive--service-instance-buffer ,instance)))
       (with-current-buffer (get-buffer-create ,buffer-sym)
	 ,@body))))

;;

(defun elhive--service-name (service)
  (symbol-name (plist-get service :name)))

(defun elhive--service-group (service)
  (plist-get service :group))

(defun elhive--service-id (service)
  (if (or (symbolp service) (stringp service)) (format "%s-%s" elhive-group service)
    (format "%s-%s"
	    (elhive--service-group service)
	    (elhive--service-name service))))

(defun elhive--service-get (service)
  (let* ((service-id (elhive--service-id service))
	 (service (gethash service-id elhive--services)))
    (unless service
      (error "Service %S is not defined" service-id))
    service))

(defun elhive--service-defaults (name service)
  (plist-put service :name name)
  (plist-put service :group elhive-group)
  (plist-put service :arguments
	     (mapcar
	      (lambda (argument) (format "%s" argument))
	      (plist-get service :arguments)))
  (plist-put service :directory
	     (or (plist-get service :directory)
		 default-directory))
  (plist-put service :environment
	     (plist-get service :environment))
  (plist-put service :hooks
	     (plist-get service :hooks))
  service)

;;

(defun elhive--service-instance-buffer (instance)
  (format "*%s-%s*"
	  elhive-buffer-name-prefix
	  (elhive--service-instance-id instance)))

(defun elhive--service-instantiate (service)
  (let ((instance (copy-sequence (elhive--service-get service))))
    (plist-put instance :group (elhive--service-instance-group instance))
    (plist-put instance :buffer (elhive--service-instance-buffer instance))
    (plist-put instance :command (executable-find (plist-get instance :command)))
    (plist-put instance :directory (expand-file-name (plist-get instance :directory)))
    (puthash (elhive--service-instance-id instance) instance
	     elhive--service-instances)))

(defun elhive--service-instance-name (instance)
  (elhive--service-name instance))

(defun elhive--service-instance-group (instance)
  (elhive--service-group instance))

(defun elhive--service-instance-id (instance)
  (elhive--service-id instance))

(defun elhive--service-instance-get (instance)
  (let* ((instance-id (elhive--service-instance-id instance))
	 (instance (gethash instance-id elhive--service-instances)))
    (unless instance
      (error "Service %S is not instantiated" instance-id))
    instance))

(defun elhive--service-instance-hook-run (instance hook)
  (let ((hook-procs (plist-get (plist-get instance :hooks) hook)))
    (when hook-procs
      (cond ((and (listp hook-procs) (not (eq (car hook-procs) 'closure)))
	     (dolist (hook-proc hook-procs) (funcall hook-proc instance)))
	    (t (funcall hook-procs instance))))))

(defun elhive--service-instance-start-process (instance)
  (let* ((process-environment (copy-sequence process-environment))
	 (process (with-elhive-service-instance-buffer instance
		    (setq default-directory (plist-get instance :directory))
		    (setq comint-scroll-to-bottom-on-output t)
		    (setq truncate-lines t)
		    (dolist (var (plist-get instance :environment))
		      (setenv (format "%s" (car var)) (cadr var)))
		    (elhive--service-instance-hook-run instance 'before)
		    (let* ((command (plist-get instance :command))
			   (buffer (plist-get instance :buffer))
			   (arguments (plist-get instance :arguments))
			   (process (apply #'start-process command buffer command arguments)))
		      (message "Started process %S with arguments %S inside %S" command arguments buffer)
		      (setq-local elhive--buffer-process process)))))
    (prog1 process
      (elhive--set-process-filters process)
      (set-process-sentinel
       process
       (lambda (process event)
	 (when (memq (process-status process) '(exit signal))
	   (with-elhive-service-instance-buffer instance
	     (goto-char (point-max))
	     (insert (format "\n\nProcess %S exited at %s with event: %S\n"
			     process (format-time-string "%Y-%m-%d %H:%M:%S" (current-time))
			     (string-clean-whitespace event))))
	   (elhive--service-instance-hook-run instance 'after)))))))

(defun elhive--service-instance-state (instance)
  (with-elhive-service-instance-buffer instance
    (let* ((process (buffer-local-value 'elhive--buffer-process
					 (current-buffer))))
      (if process
	  (let ((status (process-status process))
		(code (process-exit-status process)))
	    (cond ((memq status '(exit)) (if (= code 0) 'exit 'fail))
		  ((memq status '(signal)) 'fail)
		  (t 'active)))
	'inactive))))

;;

(defun elhive-service-start (service)
  (let ((instance (elhive--service-instantiate service)))
    (prog1 instance
      (elhive--service-instance-start-process instance))))

(defun elhive-service-stop (service)
  (let* ((instance (elhive--service-instance-get service)))
    (if instance
	(prog1 instance
	  (with-elhive-service-instance-buffer instance
	    (let ((process (get-buffer-process (current-buffer))))
	      (when process
		(kill-process process)))
	    (kill-local-variable 'elhive--buffer-process)))
      (error "Service %S is not instantiated" (elhive--service-name service)))))

(defun elhive-service-restart (service)
  (ignore-errors (elhive-service-stop service))
  (elhive-service-start service))

(defun elhive-service-state (service)
  (let* ((instance (elhive--service-instance-get service)))
    (cons (elhive--service-instance-name instance)
	  (elhive--service-instance-state instance))))

;;

(defun elhive-group-start (name)
  (let ((group (gethash name elhive--services-by-group)))
    (mapcar #'elhive-service-start
	    (hash-table-values group))))

(defun elhive-group-stop (name)
  (let ((group (gethash name elhive--services-by-group)))
    (mapcar #'elhive-service-stop
	    (hash-table-values group))))

(defun elhive-group-restart (name)
  (let ((group (gethash name elhive--services-by-group)))
    (mapcar #'elhive-service-restart
	    (hash-table-values group))))

(defun elhive-group-state (name)
  (let ((group (gethash name elhive--services-by-group)))
    (mapcar #'elhive-service-state
	    (hash-table-values group))))

;;

(defun elhive-state ()
  (mapcar (lambda (group) (list group (elhive-group-state group)))
	  (hash-table-keys elhive--services-by-group)))

;;

;; (defelhive-service test
;;   :command "bash"
;;   :arguments (-x -e -c "nc -l 2289"))

;; (defelhive-group non-default
;;   (test1 :command "bash" :arguments (-c "sleep 5"))
;;   (test2 :command "bash" :arguments (-c "sleep 10")))

;; (hash-table-keys elhive--services)
;; (hash-table-keys elhive--services-by-group)
;; (hash-table-values elhive--services)
;; (hash-table-values elhive--service-instances)

;; (elhive-group-start 'non-default)

(defun elhive-hook-port-wait (host port &optional retry-count sleep-interval)
  (lambda (instance)
    (let ((success nil)
          (retries 0))
      (while (and (not success)
		  (< retries (or retry-count 50)))
	(condition-case err
            (progn (delete-process (open-network-stream
				    (elhive--service-instance-buffer instance)
				    nil host port
				    :type 'plain
				    :coding 'no-conversion))
		   (setq success t))
          (file-error
           (let ((inhibit-message t))
             (message "Failed to connect to %s:%s with error message %s"
		      host port (error-message-string err))
             (sit-for (or sleep-interval 0.5))
             (setq retries (1+ retries))))))
      success)))

(provide 'elhive)

;;; elhive.el ends here
