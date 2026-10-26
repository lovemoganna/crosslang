;;; crosslang-entry-tests.el --- Entry and selected-text regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang-gptel)
(require 'crosslang-local)

(ert-deftest crosslang-entry-compat-command-works-in-text-buffer ()
  (with-temp-buffer
    (text-mode)
    (let ((text (buffer-string)) (processes (process-list)))
      (unwind-protect
          (progn
            (crosslang-gptel-enable)
            (should crosslang-mode)
            (should (plist-get crosslang-provider :start))
            (should-not (bound-and-true-p gptel-mode))
            (should (equal text (buffer-string)))
            (should (equal processes (process-list))))
        (crosslang-mode -1)))))

(ert-deftest crosslang-entry-direct-mode-configures-provider ()
  (with-temp-buffer
    (text-mode)
    (crosslang-mode 1)
    (unwind-protect
        (should (functionp (plist-get crosslang-provider :start)))
      (crosslang-mode -1))))

(ert-deftest crosslang-entry-no-selection-never-submits-document ()
  (with-temp-buffer
    (text-mode) (insert "private unselected document")
    (crosslang-mode 1)
    (setq-local crosslang-provider
                (list :operations '(express)
                      :start (lambda (&rest _) (ert-fail "Must not submit entire document"))))
    (unwind-protect
        (let ((error (should-error (crosslang-express) :type 'user-error)))
          (should (string-match-p "[Ss]elect" (error-message-string error))))
      (crosslang-mode -1))))

(ert-deftest crosslang-entry-scratch-full-assistance-stays-inside-selection ()
  (with-temp-buffer
    (lisp-interaction-mode) (buffer-enable-undo)
    (insert "PREFIX 只修复错误 SUFFIX")
    (crosslang-mode 1)
    (let ((original (buffer-string)) submitted
          (crosslang-assistance 'full) (transient-mark-mode t))
      (setq-local crosslang-provider
                  (list :operations '(express)
                        :start (lambda (request done)
                                 (setq submitted (plist-get request :text))
                                 (funcall done '(:text "Fix only the bug")) nil)))
      (goto-char (+ (point-min) 7)) (set-mark (point)) (forward-char 5)
      (setq mark-active t)
      (unwind-protect
          (progn
            (setq buffer-undo-list nil)
            (crosslang-express)
            (should (equal submitted "只修复错误"))
            (should (equal original (buffer-string)))
            ;; Preview/minibuffer navigation normally deactivates the region.
            (setq mark-active nil)
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
              (crosslang-accept))
            (should (equal "PREFIX Fix only the bug SUFFIX" (buffer-string)))
            (undo-only 1)
            (should (equal original (buffer-string)))
            (should-not (bound-and-true-p gptel-mode)))
        (crosslang-mode -1)))))

(ert-deftest crosslang-entry-keeps-explicit-custom-provider ()
  (with-temp-buffer
    (let ((provider (list :name "custom" :operations nil)))
      (setq-local crosslang-provider provider)
      (crosslang-mode 1)
      (unwind-protect (should (eq provider crosslang-provider)) (crosslang-mode -1)))))
