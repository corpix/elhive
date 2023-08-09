;;; elhive.el --- operate on services with emacs -*- lexical-binding:t -*-

;; Copyright (C) 2023 Dmitry Moscowski, corpix.dev

;; Author: Dmitry Moskowski <me@corpix.dev>
;; Keywords: Processes, Services

;;; Code:
(require 'ansi-color)
(require 'subr-x)

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
      (set-process-filter process
			  (lambda (process string)
			    (internal-default-process-filter process string)
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
(defvar elhive--process-service-instances (make-hash-table))

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
      `(let* ((,service-sym (elhive--service-defaults ',name ',body))
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
     ,@(mapcar (lambda (service)
		 `(defelhive-service ,@service))
	       body)))

(defmacro with-elhive-service-instance-buffer (instance &rest body)
  (declare (indent defun))
  (let ((buffer-sym (gensym)))
    `(let ((,buffer-sym (elhive--service-instance-buffer ,instance)))
       (when (get-buffer ,buffer-sym)
	 (with-current-buffer ,buffer-sym
	   ,@body)))))

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
  service)

(defun elhive--service-process-sentinel (process event)
  (when (memq (process-status process) '(exit signal))
    (let ((instance (elhive-service-instance process)))
      (with-elhive-service-instance-buffer instance
	(goto-char (point-max))
	(insert (format "\n\nProcess %S exited at %s with event: %S\n"
			process (format-time-string "%Y-%m-%d %H:%M:%S" (current-time))
			(string-clean-whitespace event))))
      (elhive--service-instance-state-set instance 'failed))))

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
    (plist-put instance :state 'stopped)
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

(defun elhive--service-instance-start-process (instance)
  (let* ((default-directory (plist-get instance :directory))
	 (process (apply #'start-process
			 (plist-get instance :command)
			 (plist-get instance :buffer)
			 (plist-get instance :command)
			 (plist-get instance :arguments))))
    (prog1 process
      (set-process-sentinel process #'elhive--service-process-sentinel))))

(defun elhive--service-instance-state-get (instance)
  (plist-get instance :state))

(defun elhive--service-instance-state-set (instance state)
  (let ((instance (elhive--service-instance-get instance)))
    (plist-put instance :state state)
    (with-elhive-service-instance-buffer instance
      (goto-char (point-max))
      (insert (format "Service %S state: %S\n" (elhive--service-instance-name instance) state)))))

;;

(defun elhive-service-instance (process)
  (gethash process elhive--process-service-instances))

(defun elhive-service-start (service)
  (let* ((instance (elhive--service-instantiate service))
	 (process (elhive--service-instance-start-process instance)))
    (prog1 instance
      (when (not (memq (elhive--service-instance-state-get instance)
		       '(started)))
	(elhive--service-instance-state-set service 'started)
	(elhive--set-process-filters process)
	(puthash process instance elhive--process-service-instances)))))

(defun elhive-service-stop (service)
  (let* ((instance (elhive--service-instance-get service)))
    (if instance
	(prog1 instance
	  (with-elhive-service-instance-buffer instance
	    (when (get-buffer-process (current-buffer))
	      (kill-process (get-buffer-process (current-buffer)))))
	  (elhive--service-instance-state-set instance 'stopped))
      (error "Service %S is not instantiated" (elhive--service-name service)))))

(defun elhive-service-restart (service)
  (ignore-errors (elhive-service-stop service))
  (elhive-service-start service))

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


(provide 'elhive)

;;; elhive.el ends here