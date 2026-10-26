;;; crosslang-ui.el --- Quiet local shadows and explicit comparison -*- lexical-binding: t; -*-
;; Presentation only: no providers, network, timers, editing hooks or text replacement.
(require 'cl-lib)
(require 'subr-x)

(defface crosslang-translation-face
  '((t (:inherit font-lock-string-face :weight normal :slant normal)))
  "Readable, theme-aware translation text without changing glyph size or spacing."
  :group 'crosslang)
(defface crosslang-shadow-face '((t (:inherit crosslang-translation-face)))
  "Temporary suggestion, visually secondary to the author's text." :group 'crosslang)
(defface crosslang-source-face '((t (:underline t)))
  "A local source span with a suggestion; preserve its syntax colors." :group 'crosslang)
(defvar crosslang-ui--hint-shown nil)

(defun crosslang-ui-lighter (state count)
  "Return a constant-sized status without scanning or evaluating model text."
  (concat " Lang"
          (pcase state
            ('working "·等待") ('ready (if (> (or count 0) 1) (format "·%d处" count) "·候选"))
            ('reading "·释义") ('blocked "·拦截") ('uncertain "·澄清")
            ('failed "·未生成") (_ ""))))

(defun crosslang-ui--edits (proposal response)
  "Copy and sort well-formed edits for display; never change accepted patch data."
  (let ((edits (plist-get response :edits)) (length (length (plist-get proposal :text))))
    (when (and (listp edits)
               (cl-every (lambda (edit)
                           (let ((start (plist-get edit :start)) (end (plist-get edit :end)))
                             (and (integerp start) (integerp end) (<= 0 start) (< start end)
                                  (<= end length) (stringp (plist-get edit :text))))) edits))
      (sort (copy-sequence edits) (lambda (a b) (< (plist-get a :start) (plist-get b :start)))))))

(defun crosslang-ui--compact (text long)
  (let ((flat (replace-regexp-in-string "[\n\r\t]+" " · " (substring-no-properties text))))
    ;; Short results stay complete. Only results already subject to the core's
    ;; >180-column full-review rule may have abbreviated local shadows.
    (if long (truncate-string-to-width flat 48 nil nil "…") flat)))

(defun crosslang-ui--overlay (start end display face help &optional source)
  (let ((overlay (make-overlay start end nil t t)))
    (overlay-put overlay 'crosslang t)
    (overlay-put overlay 'after-string (propertize display 'face face))
    (overlay-put overlay 'help-echo help)
    (when source (overlay-put overlay 'face 'crosslang-source-face))
    overlay))

(defun crosslang-ui--below-overlay (proposal end text face help)
  "Preview TEXT on virtual lines below the source, aligned with its start.
No newline is inserted into the source; native indentation and undo stay intact."
  (let ((indent (save-excursion
                  (goto-char (max (point-min) (min (point-max) (plist-get proposal :start))))
                  (skip-chars-forward " \t" (line-end-position))
                  (make-string (current-column) ?\s))))
    (save-excursion
      (goto-char end)
      ;; A source ending mid-line must never split the remaining original text.
      (unless (bolp) (end-of-line))
      (let* ((anchor (point)) (at-start (bolp))
             (lines (mapconcat (lambda (line) (concat indent line))
                               (split-string (string-trim (substring-no-properties text)) "\n") "\n"))
             (display (concat (unless at-start "\n") lines
                              (when (and at-start (not (eobp))) "\n"))))
        (crosslang-ui--overlay anchor anchor display face help)))))

(defun crosslang-ui-render (proposal response issues)
  "Return owned overlays, state and count, without touching source or windows."
  (let* ((text (or (plist-get response :text) "暂无结果"))
         (express (eq (plist-get proposal :operation) 'express))
         (uncertain (plist-get response :uncertain))
         (edits (when express (crosslang-ui--edits proposal response)))
         (end (min (point-max) (max (point-min)
                    (or (when-let* ((marker (plist-get proposal :anchor))) (marker-position marker))
                        (plist-get proposal :end)))))
         (long (> (string-width (replace-regexp-in-string "[\n\r]+" " · " text)) 180))
         overlays state)
    (cond
     ((and express (eq (plist-get proposal :layout) 'below))
      (setq state (cond (uncertain 'uncertain) (issues 'blocked) (t 'ready)))
      (push (crosslang-ui--below-overlay proposal end
               (cond (uncertain "[需澄清]") (issues "[已拦截]")
                     (long (crosslang-ui--compact text t)) (t text))
               (if (or uncertain issues) 'warning 'crosslang-shadow-face)
               (if issues (string-join issues "；") text)) overlays))
     (uncertain
      (setq state 'uncertain)
      (push (crosslang-ui--overlay end end " [需澄清]" 'warning text) overlays))
     (issues
      (setq state 'blocked)
      (push (crosslang-ui--overlay end end " [已拦截]" 'warning (string-join issues "；")) overlays))
     (edits
      (setq state 'ready)
      (dolist (edit edits)
        (let ((start (+ (plist-get proposal :start) (plist-get edit :start)))
              (end (+ (plist-get proposal :start) (plist-get edit :end)))
              (replacement (plist-get edit :text)))
          (push (crosslang-ui--overlay start end
                   (concat " ⟨" (crosslang-ui--compact (string-trim replacement) long) "⟩")
                   'crosslang-shadow-face replacement t) overlays))))
     (t
      (setq state (if express 'ready 'reading))
      (push (crosslang-ui--overlay end end
               (concat (if express " ⟨整段：" " ⟨") (crosslang-ui--compact text long) "⟩")
               'crosslang-shadow-face text) overlays)))
    (unless crosslang-ui--hint-shown
      (setq crosslang-ui--hint-shown t)
      (message "%s" (pcase state
                       ((or 'blocked 'uncertain) "候选不能接受；SPC - v 查看原因")
                       ('reading "SPC - v 查看完整释义；SPC - c 取消")
                       (_ "SPC - v 查看对照；SPC - RET 确认；SPC - c 取消"))))
    (list :overlays overlays :state state :count (length edits))))

(defun crosslang-ui--heading (text)
  (insert (propertize text 'face 'bold) "\n"))

(defun crosslang-ui-insert-details (proposal response issues flags)
  "Insert comparison into the dedicated preview, using existing result data."
  (let* ((source (plist-get proposal :text))
         (text (or (plist-get response :text) "暂无结果"))
         (express (eq (plist-get proposal :operation) 'express))
         (edits (when express (crosslang-ui--edits proposal response)))
         (index 0))
    (crosslang-ui--heading (if express
                             (concat "表达核对" (pcase (plist-get proposal :target)
                                                    ("zh" " · 英→中")
                                                    ("en" " · 中→英")
                                                    (_ "")))
                           "阅读辅助"))
    (insert (if express "确认只写回原文；发送仍由你操作。\n\n" "原始消息保持不变。\n\n"))
    (when (plist-get response :uncertain)
      (insert (propertize "需要澄清，当前结果不能接受。\n\n" 'face 'warning)))
    (dolist (issue issues) (insert (propertize (concat "已拦截：" issue "\n") 'face 'warning)))
    (when issues (insert "\n"))
    (when edits
      (crosslang-ui--heading (format "片段对照 · %d 处" (length edits)))
      (dolist (edit edits)
        (setq index (1+ index))
        (insert (format "%d. 原片段：%s\n   候选：" index
                        (substring-no-properties source (plist-get edit :start) (plist-get edit :end)))
                (propertize (substring-no-properties (plist-get edit :text))
                            'face 'crosslang-translation-face) "\n\n"))
      (insert "其余部分保持不变；下方可核对完整语境。\n\n"))
    (when (and express (not edits) (not (plist-get response :uncertain)))
      (insert "整段候选：此结果没有局部补丁，接受会替换所请求的范围。\n\n"))
    (when express
      (crosslang-ui--heading "需人工核对")
      (dolist (flag flags) (insert "• " flag "\n"))
      (insert "\n"))
    (crosslang-ui--heading "完整原文")
    (insert (substring-no-properties source) "\n\n")
    (crosslang-ui--heading (if express "完整候选" "完整释义"))
    (insert (propertize (substring-no-properties text) 'face 'crosslang-translation-face) "\n\n")
    (insert (propertize (concat "来源：" (or (plist-get response :source) "当前语言后端")) 'face 'shadow) "\n")))

(provide 'crosslang-ui)
;;; crosslang-ui.el ends here
