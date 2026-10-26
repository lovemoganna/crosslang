;;; crosslang-style.el --- Owned translation styling, never text properties -*- lexical-binding: t; -*-
(require 'crosslang-ui)
(defvar-local crosslang-style--overlays nil)
(defvar crosslang-style--pending nil)

(defun crosslang-style--remove (overlay)
  (let ((buffer (overlay-buffer overlay)))
    (when (buffer-live-p buffer)
      (with-current-buffer buffer
        (setq crosslang-style--overlays (delq overlay crosslang-style--overlays)))))
  (delete-overlay overlay))

(defun crosslang-style--edited (overlay after &rest _)
  "Drop only the edited translation's decoration, without changing its text."
  (unless after (crosslang-style--remove overlay)))

(defun crosslang-style-clear ()
  "Clear owned translation faces without touching content, undo, point or windows."
  (mapc #'delete-overlay crosslang-style--overlays)
  (setq crosslang-style--overlays nil)
  (remove-hook 'crosslang-mode-hook #'crosslang-style--parent-changed t)
  (remove-hook 'change-major-mode-hook #'crosslang-style-clear t)
  (remove-hook 'kill-buffer-hook #'crosslang-style-clear t))

(defun crosslang-style--parent-changed ()
  (unless (bound-and-true-p crosslang-mode) (crosslang-style-clear)))

(defun crosslang-style-clear-region (start end)
  (dolist (overlay (copy-sequence crosslang-style--overlays))
    (when (and (overlay-buffer overlay)
               (< (overlay-start overlay) end) (> (overlay-end overlay) start))
      (crosslang-style--remove overlay))))

(defun crosslang-style-region (start end)
  "Style a known generated range only. Do not guess languages in existing prose."
  (when (and (bound-and-true-p crosslang-mode) (< start end))
    (crosslang-style-clear-region start end)
    (let ((overlay (make-overlay start end nil t nil)))
      (overlay-put overlay 'crosslang-translation t)
      (overlay-put overlay 'face 'crosslang-translation-face)
      (overlay-put overlay 'priority 5)
      (overlay-put overlay 'evaporate t)
      (overlay-put overlay 'modification-hooks '(crosslang-style--edited))
      (overlay-put overlay 'insert-in-front-hooks '(crosslang-style--edited))
      (overlay-put overlay 'insert-behind-hooks '(crosslang-style--edited))
      (push overlay crosslang-style--overlays))
    (add-hook 'crosslang-mode-hook #'crosslang-style--parent-changed nil t)
    (add-hook 'change-major-mode-hook #'crosslang-style-clear nil t)
    (add-hook 'kill-buffer-hook #'crosslang-style-clear nil t)))

(defun crosslang-style-note-region (start end)
  "Collect moving bounds until the surrounding write transaction succeeds."
  (push (cons (copy-marker start) (copy-marker end)) crosslang-style--pending))

(defmacro crosslang-style-transaction (&rest body)
  "Apply styles only after BODY completes; release all temporary markers."
  (declare (indent 0))
  `(let ((crosslang-style--pending nil))
     (unwind-protect
         (prog1 (progn ,@body)
           (dolist (range crosslang-style--pending)
             (crosslang-style-region (marker-position (car range)) (marker-position (cdr range)))))
       (dolist (range crosslang-style--pending)
         (set-marker (car range) nil) (set-marker (cdr range) nil)))))

(provide 'crosslang-style)
;;; crosslang-style.el ends here
