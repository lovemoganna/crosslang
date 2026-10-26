;;; crosslang-local.el --- Local-only async language providers -*- lexical-binding: t; -*-
(require 'crosslang)
(require 'json)
(defconst crosslang-local--directory (file-name-directory (or load-file-name buffer-file-name)))
(defcustom crosslang-local-python "python" "Python 3 executable; standard library only." :type 'string)
(defcustom crosslang-local-dictionaries
  (expand-file-name "dictionaries/" crosslang-local--directory)
  "Existing StarDict directory. Read only; never installs or builds caches." :type 'directory)
(defcustom crosslang-local-model 'auto
  "Model selection for the running local LM Studio/Bionic server.
Auto uses the sole already-loaded text model. Multiple models require a choice.
A string requires that exact loaded ID; nil disables generation.
The provider never starts a server, pulls a model or uses remote endpoints."
  :type '(choice (const :tag "Current loaded model" auto)
                 (const :tag "Dictionary only" nil) string))
(defcustom crosslang-local-port 1234 "Port of an already running loopback-only local API." :type 'integer)

(defun crosslang-local--start (request callback)
  (let* ((output (generate-new-buffer " *crosslang output*"))
         (errors (generate-new-buffer " *crosslang errors*"))
         (payload (list :operation (symbol-name (plist-get request :operation))
                        :text (plist-get request :text) :target (plist-get request :target)
                        :assistance (symbol-name (plist-get request :assistance))
                        :context (or (plist-get request :context) "")
                        :spans (vconcat (plist-get request :spans))
                        :dictionary crosslang-local-dictionaries
                        :port crosslang-local-port
                        :model (if (eq crosslang-local-model 'auto) "@loaded"
                                 crosslang-local-model)))
         (coding-system-for-read 'utf-8-unix)
         (coding-system-for-write 'utf-8-unix)
         process)
    (condition-case err
        (progn
          (setq process
                (make-process
                 :name "crosslang-local" :buffer output :stderr errors :noquery t
                 :connection-type 'pipe :coding '(utf-8-unix . utf-8-unix)
                 :command (list crosslang-local-python "-B" "-X" "utf8"
                                (expand-file-name "local_worker.py" crosslang-local--directory))
                 :sentinel
                 (lambda (proc _event)
                   (when (memq (process-status proc) '(exit signal))
                     (unwind-protect
                         (funcall callback
                                  (condition-case nil
                                      (with-current-buffer output
                                        (goto-char (point-min))
                                        (json-parse-buffer :object-type 'plist :array-type 'list
                                                           :false-object nil :null-object nil))
                                    (error (list :error "Local backend failed or returned invalid data"))))
                       (when (buffer-live-p output) (kill-buffer output))
                       (when (buffer-live-p errors) (kill-buffer errors)))))))
          (process-send-string process (json-serialize payload))
          (process-send-eof process)
          (lambda () (when (process-live-p process) (delete-process process))
            (when (buffer-live-p output) (kill-buffer output))
            (when (buffer-live-p errors) (kill-buffer errors))))
      (error
       (when (and process (process-live-p process)) (delete-process process))
       (when (buffer-live-p output) (kill-buffer output))
       (when (buffer-live-p errors) (kill-buffer errors))
       (funcall callback (list :error (error-message-string err))) nil))))

(defun crosslang-local-use ()
  "Select local provider for this conversation only. No model is downloaded."
  (interactive)
  (setq-local crosslang-provider
              (list :name "Local dictionary / explicit local model"
                    :operations (if crosslang-local-model '(explain translate express) '(explain))
                    :start #'crosslang-local--start)))

(provide 'crosslang-local)
