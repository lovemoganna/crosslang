;;; crosslang-gptel.el --- Draft-only gptel adapter -*- lexical-binding: t; -*-
(require 'crosslang)

(defun crosslang-gptel--active-p () (bound-and-true-p gptel-mode))

(defun crosslang-gptel--bounds ()
  "Return final user turn after a native gptel prompt.
No requests are created, aborted, or sent. Refuse response/history positions.
Unsupported layouts require selecting a known draft after a native prompt."
  (unless (and (bound-and-true-p gptel-mode) (fboundp 'gptel-prompt-prefix-string))
    (user-error "Use a gptel conversation buffer"))
  (when (buffer-narrowed-p)
    (user-error "Widen the conversation before requesting an expression candidate"))
  (when (and (boundp 'gptel--request-alist) (fboundp 'gptel-fsm-info)
             (cl-some (lambda (entry)
                        (eq (plist-get (gptel-fsm-info (cadr entry)) :buffer)
                            (current-buffer))) gptel--request-alist))
    (user-error "gptel is responding; reading assistance remains available"))
  (let ((prefix (gptel-prompt-prefix-string)) (end (point-max)) start)
    (unless (and (stringp prefix) (not (string-empty-p prefix)))
      (user-error "Cannot safely identify an empty gptel prompt prefix"))
    (save-excursion
      (goto-char end)
      (unless (re-search-backward (concat "^" (regexp-quote prefix)) nil t)
        (user-error "No final gptel prompt found; use gptel's normal new prompt"))
      (setq start (match-end 0)))
    ;; A historical prompt followed by a reply is never an editable draft.
    (when (text-property-not-all start end 'gptel nil)
      (user-error "Final turn contains an Agent response; wait for its next prompt"))
    (when (or buffer-read-only (text-property-not-all start end 'read-only nil))
      (user-error "Draft is read-only"))
    (cons start end)))

(add-to-list 'crosslang-adapters '(crosslang-gptel--active-p . crosslang-gptel--bounds))

(defun crosslang-gptel--context (bounds)
  "Read at most 1500 chars from the nearest preceding response, never tools."
  (save-restriction
    (widen)
    (let ((pos (car bounds)) context)
      (while (and (> pos (point-min)) (not context))
        (let ((previous (previous-single-property-change pos 'gptel nil (point-min))))
          (when (eq (get-text-property (1- pos) 'gptel) 'response)
            (setq context (buffer-substring-no-properties (max previous (- pos 1500)) pos)))
          (setq pos previous)))
      context)))

(put 'crosslang-gptel--bounds 'crosslang-context-function #'crosslang-gptel--context)

(defun crosslang-gptel-enable ()
  "Compatibility entry for `crosslang-enable'.
Use the gptel adapter in a chat, selected-text assistance in an ordinary editor.
Never creates a conversation or changes an existing gptel backend."
  (interactive)
  (crosslang-enable))

(provide 'crosslang-gptel)
