;;; crosslang-pair.el --- Explicitly enabled bilingual body maintenance -*- lexical-binding: t; -*-
(require 'crosslang-live)

(defvar-local crosslang-pair--source nil)
(defvar-local crosslang-pair--target nil)
(defvar-local crosslang-pair--last-target nil)
(defvar-local crosslang-pair--old-bounds nil)
(defvar-local crosslang-pair--stale nil)
(defvar crosslang-pair--writing nil)

(defun crosslang-pair--bounds ()
  "Use only the tracked source, never the generated second language."
  (unless (and crosslang-pair-mode crosslang-pair--source)
    (user-error "没有受管理的双语原文"))
  (let ((start (marker-position (car crosslang-pair--source)))
        (end (marker-position (cdr crosslang-pair--source)))
        (draft (crosslang--bounds)))
    (unless (and start end (< start end) (<= start (point)) (<= (point) end)
                 (<= (car draft) start) (<= end (cdr draft)))
      (user-error "请在受管理的原文中继续写作"))
    (cons start end)))

(defun crosslang-pair--authorized-p (proposal)
  "Prove ownership of both source and target before an automatic body edit."
  (and crosslang-pair-mode (eq (plist-get proposal :layout) 'below)
       (equal (cons (plist-get proposal :start) (plist-get proposal :end))
              (crosslang-pair--bounds))
       (or (not crosslang-pair--target)
           (let ((start (marker-position (car crosslang-pair--target)))
                 (end (marker-position (cdr crosslang-pair--target)))
                 (source-end (marker-position (cdr crosslang-pair--source)))
                 (draft (crosslang--bounds)))
             (and start end (<= start end) (<= end (cdr draft))
                  (= start (1+ source-end))
                  (equal "\n" (buffer-substring-no-properties source-end start))
                  (not (text-property-not-all start end 'read-only nil))
                  (equal crosslang-pair--last-target (buffer-substring-no-properties start end)))))))

(defun crosslang-pair--write (candidate)
  "Update only the owned target; called inside the core's undo transaction."
  (let ((crosslang-pair--writing t) (crosslang-live--internal-change t)
        (source-end (marker-position (cdr crosslang-pair--source))))
    (if crosslang-pair--target
        (unless (equal candidate crosslang-pair--last-target)
          (goto-char (car crosslang-pair--target))
          (delete-region (car crosslang-pair--target) (cdr crosslang-pair--target))
          (insert candidate))
      (goto-char source-end) (insert "\n" candidate)
      (set-marker (cdr crosslang-pair--source) source-end)
      (setq crosslang-pair--target
            (cons (copy-marker (1+ source-end)) (copy-marker (point) t))))
    (setq crosslang-pair--last-target candidate crosslang-pair--stale nil)
    (crosslang-style-note-region (car crosslang-pair--target) (cdr crosslang-pair--target))))

(defun crosslang-pair--result ()
  (when (and crosslang-pair-mode crosslang--proposal
             (eq (plist-get crosslang--proposal :layout) 'below))
    (condition-case err
        (let ((crosslang--automatic-writer
               (list :authorize #'crosslang-pair--authorized-p :write #'crosslang-pair--write)))
          ;; The user's typing position is preserved while the second line updates.
          (save-excursion (crosslang-accept)))
      (user-error (message "双语自动写入暂停：%s" (error-message-string err))))))

(defun crosslang-pair--before-change (beg end)
  (when (and crosslang-pair-mode (not crosslang-pair--writing))
    (let ((source-end (marker-position (cdr crosslang-pair--source))))
      (cond
       ((or (bound-and-true-p undo-in-progress)
            (and crosslang-pair--target
                 (let ((target-end (marker-position (cdr crosslang-pair--target))))
                   (if (= beg end) (and (> beg source-end) (<= beg target-end))
                     (and (< beg target-end) (> end source-end))))))
        (crosslang-pair-mode -1)
        (message "已停止双语自动维护；保留两份正文及你的修改。"))
       ((and (<= beg source-end) (>= end (marker-position (car crosslang-pair--source))))
        (setq crosslang-pair--stale t)
        (force-mode-line-update))))))

(defun crosslang-pair--parent-changed ()
  (when (and crosslang-pair-mode (or (not crosslang-mode) (not crosslang-live-mode)))
    (crosslang-pair-mode -1)))

(defun crosslang-pair--stop ()
  (crosslang-pair-mode -1))

(define-minor-mode crosslang-pair-mode
  "Explicitly authorize automatic bilingual edits for the current input line.
Source stays intact; only this mode's generated second language is refreshed.
Turning off never deletes either language, saves a file or sends a message."
  :lighter (:eval (if crosslang-pair--stale " Pair·待更新" " Pair"))
  (if crosslang-pair-mode
      (condition-case err
          (let* ((draft (if (crosslang--adapter) (crosslang--bounds)
                          (crosslang--editable-line-bounds)))
                 (start (max (car draft) (line-beginning-position)))
                 (end (min (cdr draft) (line-end-position))))
            (when (or buffer-read-only (minibufferp) (use-region-p) (>= start end))
              (user-error "请在可编辑的原文行中开启双语写作，不要选择文本"))
            (when (eq crosslang-assistance 'partial) (user-error "双语写作需要 on-demand 或 full 辅助"))
            (unless crosslang-mode (crosslang-enable))
            (crosslang--cleanup)
            (setq crosslang-pair--source (cons (copy-marker start) (copy-marker end t))
                  crosslang-pair--old-bounds crosslang-live-bounds-function
                  crosslang-pair--stale t)
            (setq-local crosslang-live-bounds-function #'crosslang-pair--bounds)
            (add-hook 'crosslang-result-hook #'crosslang-pair--result nil t)
            (add-hook 'before-change-functions #'crosslang-pair--before-change nil t)
            (add-hook 'crosslang-live-mode-hook #'crosslang-pair--parent-changed nil t)
            (add-hook 'crosslang-mode-hook #'crosslang-pair--parent-changed nil t)
            (add-hook 'change-major-mode-hook #'crosslang-pair--stop nil t)
            (add-hook 'kill-buffer-hook #'crosslang-pair--stop nil t)
            (crosslang-live-mode 1)
            (message "双语写作开启：原文保留，译文自动写入及刷新；SPC - w 关闭，不保存、不发送。"))
        (error (crosslang-pair-mode -1) (signal (car err) (cdr err))))
    (remove-hook 'crosslang-result-hook #'crosslang-pair--result t)
    (remove-hook 'before-change-functions #'crosslang-pair--before-change t)
    (remove-hook 'crosslang-live-mode-hook #'crosslang-pair--parent-changed t)
    (remove-hook 'crosslang-mode-hook #'crosslang-pair--parent-changed t)
    (remove-hook 'change-major-mode-hook #'crosslang-pair--stop t)
    (remove-hook 'kill-buffer-hook #'crosslang-pair--stop t)
    (when (eq crosslang-live-bounds-function #'crosslang-pair--bounds)
      (setq-local crosslang-live-bounds-function crosslang-pair--old-bounds)
      (when crosslang-live-mode (crosslang-live-mode -1)))
    (when crosslang-pair--target
      (crosslang-style-clear-region (car crosslang-pair--target) (cdr crosslang-pair--target)))
    (dolist (marker (append (list (car crosslang-pair--source) (cdr crosslang-pair--source))
                            (list (car crosslang-pair--target) (cdr crosslang-pair--target))))
      (when (markerp marker) (set-marker marker nil)))
    (setq crosslang-pair--source nil crosslang-pair--target nil
          crosslang-pair--last-target nil crosslang-pair--stale nil)))

(provide 'crosslang-pair)
;;; crosslang-pair.el ends here
