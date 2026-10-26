;;; crosslang-org.el --- Current prose paragraph, never the Org document -*- lexical-binding: t; -*-
(require 'crosslang)

(defun crosslang-org--active-p ()
  (and (derived-mode-p 'org-mode) (not (bound-and-true-p gptel-mode))))

(defun crosslang-org--bounds ()
  "Return an explicit selection, or the current editable prose paragraph.
Explicit selections retain the existing manual workflow. Automatic requests
never run with a selection, and cannot target Org structural elements."
  (unless (crosslang-org--active-p) (user-error "当前不是普通 Org 文档"))
  (when buffer-read-only (user-error "当前 Org 文档只读"))
  (if (use-region-p)
      (crosslang--selected-bounds)
    (require 'org-element)
    (let* ((context (org-element-context))
           (paragraph (org-element-lineage context '(paragraph) t))
           (blocked (org-element-lineage context
                      '(src-block inline-src-block example-block export-block comment-block
                        property-drawer node-property drawer keyword comment table table-row table-cell
                        fixed-width babel-call code verbatim) t)))
      (unless (and paragraph (not blocked))
        (user-error "请在 Org 正文段落中使用动态辅助；标题、代码块、属性等不自动处理"))
      (let ((start (max (point-min) (org-element-property :begin paragraph)))
            (end (min (point-max) (org-element-property :end paragraph))))
        (save-excursion
          (goto-char end) (skip-chars-backward "\n\r" start) (setq end (point)))
        (unless (and (< start end) (<= start (point))
                     (<= (point) (org-element-property :end paragraph))
                     (not (text-property-not-all start end 'read-only nil)))
          (user-error "当前不是可编辑的 Org 正文段落"))
        (cons start end)))))

(defun crosslang-org--dwim ()
  "Express Chinese prose; keep selected English explanation behavior."
  (let ((bounds (condition-case nil (crosslang-org--bounds) (user-error nil))))
    (if (and bounds (save-excursion (goto-char (car bounds))
                                   (re-search-forward "[㐀-鿿]" (cdr bounds) t)))
        (crosslang-express)
      (crosslang-explain))))

(add-to-list 'crosslang-adapters '(crosslang-org--active-p . crosslang-org--bounds))
(put 'crosslang-org--bounds 'crosslang-dwim-function #'crosslang-org--dwim)
(provide 'crosslang-org)
;;; crosslang-org.el ends here
