;;; crosslang-live.el --- Opt-in idle suggestions for a gptel draft -*- lexical-binding: t; -*-
(require 'crosslang-gptel)
(require 'crosslang-org)

(defcustom crosslang-live-delay 1.0
  "Seconds of input inactivity before suggesting a Chinese/English translation."
  :type 'number :group 'crosslang)
(defcustom crosslang-live-max-characters 2000
  "Maximum draft size for automatic requests. Manual requests remain available."
  :type 'integer :group 'crosslang)
(defvar-local crosslang-live--timer nil)
(defvar-local crosslang-live--epoch 0)
(defvar-local crosslang-live--dirty nil)
(defvar-local crosslang-live--attempted-tick nil)
(defvar-local crosslang-live--owned-generation nil)
(defvar crosslang-live--dispatching nil)
(defvar crosslang-live--internal-change nil)
(defvar-local crosslang-live-bounds-function nil
  "Optional narrow input-scope function; protected adapter bounds still apply on write.")

(defun crosslang-live--cancel-timer ()
  (cl-incf crosslang-live--epoch)
  (when (timerp crosslang-live--timer) (cancel-timer crosslang-live--timer))
  (setq crosslang-live--timer nil))

(defun crosslang-live--cancel-owned ()
  "Cancel only the request/result created by this automatic mode."
  (let ((owned crosslang-live--owned-generation))
    (setq crosslang-live--owned-generation nil)
    (when (and owned (= owned crosslang--generation)) (crosslang--cleanup))))

(defun crosslang-live--suspend ()
  "Do not regenerate this revision after dismissal, acceptance or manual help."
  (crosslang-live--cancel-timer)
  (crosslang-live--cancel-owned)
  (setq crosslang-live--dirty nil
        crosslang-live--attempted-tick (buffer-chars-modified-tick)))

(defun crosslang-live--manual-request ()
  (unless crosslang-live--dispatching (crosslang-live--suspend)))

(defun crosslang-live--composing-p ()
  "Recognize Emacs input-method preedit and queued input, without changing IME.
Native OS preedit not exposed to Emacs cannot be inspected here."
  (or (and (boundp 'quail-current-key) (stringp quail-current-key)
           (not (string-empty-p quail-current-key)))
      (bound-and-true-p quail-converting)
      unread-command-events (input-pending-p)))

(defun crosslang-live--focused-p ()
  (and (eq (window-buffer (selected-window)) (current-buffer))
       (not (active-minibuffer-window)) (not (bound-and-true-p isearch-mode))))

(defun crosslang-live--target (text)
  "Select the other language without another model request.
Chinese or mixed input completes into English; English-only input into Chinese.
Numbers, punctuation and whitespace alone do not select a language."
  (cond ((string-match-p "[㐀-鿿]" text) "en")
        ((string-match-p "[A-Za-z]" text) "zh")))

(defun crosslang-live--ready-bounds ()
  "Inspect the draft only after idling, never in an editing hook."
  (when (and (bound-and-true-p crosslang-live-mode) crosslang-mode
             (not (use-region-p)) (not crosslang--review)
             (memq crosslang-assistance '(on-demand full))
             (memq 'express (plist-get crosslang-provider :operations))
             (crosslang-live--focused-p) (not (crosslang-live--composing-p))
             (not crosslang--timer) (not crosslang--proposal))
    (when-let* ((bounds (condition-case nil
                           (if crosslang-live-bounds-function (funcall crosslang-live-bounds-function)
                             (if (crosslang--adapter) (crosslang--bounds)
                               (crosslang--editable-line-bounds)))
                         (user-error nil))))
      (when (and (>= (point) (car bounds))
                 (<= (- (cdr bounds) (car bounds)) crosslang-live-max-characters)
                 (crosslang-live--target
                  (buffer-substring-no-properties (car bounds) (cdr bounds))))
        bounds))))

(defun crosslang-live--fire (buffer epoch tick)
  (when (buffer-live-p buffer)
    (with-current-buffer buffer
      (when (and (bound-and-true-p crosslang-live-mode) (= epoch crosslang-live--epoch))
        (setq crosslang-live--timer nil)
        (when (and crosslang-live--dirty (= tick (buffer-chars-modified-tick))
                   (not (equal tick crosslang-live--attempted-tick)))
          (when-let* ((bounds (crosslang-live--ready-bounds)))
            ;; Mark the attempt before starting: failure is not an automatic retry.
            (setq crosslang-live--attempted-tick tick crosslang-live--dirty nil)
            (let ((crosslang-live--dispatching t))
              (condition-case err
                  (progn
                    (crosslang--request 'express bounds nil
                      (crosslang-live--target
                       (buffer-substring-no-properties (car bounds) (cdr bounds))))
                    (when (or crosslang--timer crosslang--proposal)
                      (setq crosslang-live--owned-generation crosslang--generation)))
                (error (message "动态语言辅助未生成：%s；原文保留" (error-message-string err)))))))))))

(defun crosslang-live--queue (&rest _)
  "Schedule one quiet-period callback; do no parsing or model work here."
  (when (and (not crosslang-live--internal-change)
             (bound-and-true-p crosslang-live-mode) crosslang-mode crosslang-live--dirty
             (not crosslang-live--timer)
             (not (equal crosslang-live--attempted-tick (buffer-chars-modified-tick))))
    (setq crosslang-live--timer
          (run-at-time (max 0.1 crosslang-live-delay) nil #'crosslang-live--fire
                       (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))))

(defun crosslang-live--post-command ()
  ;; Cursor movement and other commands also start a fresh quiet period.
  (when (and crosslang-live--dirty
             (not (equal crosslang-live--attempted-tick (buffer-chars-modified-tick))))
    (crosslang-live--cancel-timer)
    (crosslang-live--queue)))

(defun crosslang-live--before-change (&rest _)
  (unless crosslang-live--internal-change
    (crosslang-live--cancel-timer)
    (crosslang-live--cancel-owned)
    (setq crosslang-live--dirty t)))

(defun crosslang-live--parent-changed ()
  (unless crosslang-mode (crosslang-live-mode -1)))

(defun crosslang-live--resource-error (response)
  "Turn automatic requests off on missing resources, leaving manual help intact."
  (when (and crosslang-live-mode
             (or crosslang-live--dispatching
                 (and crosslang-live--owned-generation
                      (= crosslang-live--owned-generation crosslang--generation)))
             (member (plist-get response :error_code)
                     '("model-not-loaded" "selected-model-not-loaded" "model-selection-required" "service-unavailable")))
    (crosslang-live-mode -1)
    (concat (crosslang--format-error response) "；动态辅助已关闭，准备好模型后按 SPC - SPC 重试")))

(defun crosslang-live--stop ()
  (crosslang-live--cancel-timer)
  (crosslang-live--cancel-owned)
  (setq crosslang-live--dirty nil)
  (remove-hook 'before-change-functions #'crosslang-live--before-change t)
  (remove-hook 'after-change-functions #'crosslang-live--queue t)
  (remove-hook 'post-command-hook #'crosslang-live--post-command t)
  (remove-hook 'gptel-post-response-functions #'crosslang-live--queue t)
  (remove-hook 'crosslang-before-request-hook #'crosslang-live--manual-request t)
  (remove-hook 'crosslang-dismiss-hook #'crosslang-live--suspend t)
  (remove-hook 'crosslang-after-accept-hook #'crosslang-live--suspend t)
  (remove-hook 'crosslang-error-functions #'crosslang-live--resource-error t)
  (remove-hook 'crosslang-mode-hook #'crosslang-live--parent-changed t)
  (remove-hook 'change-major-mode-hook #'crosslang-live--stop t)
  (remove-hook 'kill-buffer-hook #'crosslang-live--stop t))

;;;###autoload
(define-minor-mode crosslang-live-mode
  "Opt-in suggestions in any major mode's editable buffer.
Use an existing adapter's protected scope, otherwise only the current line."
  :lighter " Live"
  (if crosslang-live-mode
      (condition-case err
          (progn
            (when (or buffer-read-only (minibufferp))
              (user-error "动态辅助需要可编辑缓冲区；不修改只读内容"))
            (when (eq crosslang-assistance 'partial)
              (user-error "局部辅助要求选区；先用 SPC - s 选择 on-demand 或 full"))
            (unless crosslang-mode (crosslang-enable))
            (unless (memq 'express (plist-get crosslang-provider :operations))
              (user-error "当前后端不支持表达生成；原有词典功能仍可使用"))
            (crosslang-live--stop)
            (setq crosslang-live--attempted-tick nil crosslang-live--dirty t)
            (add-hook 'before-change-functions #'crosslang-live--before-change nil t)
            (add-hook 'after-change-functions #'crosslang-live--queue nil t)
            (add-hook 'post-command-hook #'crosslang-live--post-command nil t)
            (add-hook 'gptel-post-response-functions #'crosslang-live--queue nil t)
            (add-hook 'crosslang-before-request-hook #'crosslang-live--manual-request nil t)
            (add-hook 'crosslang-dismiss-hook #'crosslang-live--suspend nil t)
            (add-hook 'crosslang-after-accept-hook #'crosslang-live--suspend nil t)
            (add-hook 'crosslang-error-functions #'crosslang-live--resource-error nil t)
            (add-hook 'crosslang-mode-hook #'crosslang-live--parent-changed nil t)
            (add-hook 'change-major-mode-hook #'crosslang-live--stop nil t)
            (add-hook 'kill-buffer-hook #'crosslang-live--stop nil t)
            (crosslang-live--queue)
            (message "动态辅助开启：停笔约 %.1f 秒生成候选；SPC - RET 确认，SPC - c 取消，SPC - SPC 关闭" crosslang-live-delay))
        (error (setq crosslang-live-mode nil) (crosslang-live--stop) (signal (car err) (cdr err))))
    (crosslang-live--stop)
    (message "动态辅助关闭；手动辅助仍可使用")))

(define-key crosslang-short-map (kbd "SPC") #'crosslang-live-mode)
(provide 'crosslang-live)
;;; crosslang-live.el ends here
