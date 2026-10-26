;;; crosslang-hydra-tests.el --- Menu and lifecycle integration -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(defvar revolt-map (make-sparse-keymap))
(require 'crosslang-init)
(defconst crosslang-hydra-test--lazy-at-entry
  (and (autoloadp (symbol-function 'hydra-crosslang/body))
       (not (featurep 'crosslang-hydra))))
(require 'crosslang-hydra)

(defmacro crosslang-hydra-test--with (&rest body)
  `(save-window-excursion (with-temp-buffer
     (switch-to-buffer (current-buffer))
     (org-mode)
     (insert "Please check 交付日期.")
     (crosslang-mode 1)
     (unwind-protect (progn ,@body)
       (hydra-keyboard-quit)
       (crosslang-mode -1)))))

(defun crosslang-hydra-test--head (key)
  (let ((command (lookup-key hydra-crosslang/keymap (kbd key))))
    (should (commandp command))
    (call-interactively command)))

(ert-deftest crosslang-hydra-entry-is-lazy-and-scoped ()
  (should crosslang-hydra-test--lazy-at-entry)
  (let ((global (global-key-binding (kbd "M--"))))
    (crosslang-hydra-test--with
      (should (eq (lookup-key revolt-map (kbd "-")) 'hydra-crosslang/body))
      (should (eq (key-binding (kbd "M--")) global))
      (should (eq (key-binding (kbd "C-c L e")) 'crosslang-express))
      (crosslang-mode -1)
      (should (eq (key-binding (kbd "M--")) global)))))

(ert-deftest crosslang-hydra-opening-and-quitting-are-inert ()
  (crosslang-hydra-test--with
    (buffer-enable-undo)
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point))
          (processes (process-list))
          (proposal (list :text "sentinel")))
      (setq crosslang--proposal proposal)
      (dolist (quit '("q" "<escape>" "C-g"))
        (hydra-crosslang/body)
        (should (eq hydra-curr-body-fn 'hydra-crosslang/body))
        (crosslang-hydra-test--head quit)
        (should-not hydra-curr-map)
        (should (eq proposal crosslang--proposal)))
      (should (equal text (buffer-string)))
      (should (equal undo buffer-undo-list))
      (should (= position (point)))
      (should (equal processes (process-list)))
      (should-not crosslang-live-mode))))

(ert-deftest crosslang-hydra-actions-dispatch-and-exit ()
  (crosslang-hydra-test--with
    (dolist (entry '(("-" . crosslang-dwim) ("e" . crosslang-express)
                     ("d" . crosslang-explain) ("t" . crosslang-translate)
                     ("v" . crosslang-show-details) ("RET" . crosslang-accept)
                     ("a" . crosslang-accept) ("c" . crosslang-dismiss)
                     ("b" . crosslang-insert-bilingual)
                     ("s" . crosslang-set-assistance) ("x" . crosslang-toggle-context)
                     ("r" . crosslang-review-start) ("R" . crosslang-review-finish)))
      (let ((calls 0))
        (cl-letf (((symbol-function (cdr entry))
                   (lambda (&rest _) (interactive) (setq calls (1+ calls)))))
          (hydra-crosslang/body)
          (crosslang-hydra-test--head (car entry))
          (should (= calls 1))
          (should-not hydra-curr-map))))))

(ert-deftest crosslang-hydra-space-toggles-live-without-request ()
  (crosslang-hydra-test--with
    (setq-local crosslang-provider
                (list :operations '(express) :start (lambda (&rest _) (ert-fail "Unexpected request"))))
    (crosslang-hydra-test--head "SPC")
    (should crosslang-live-mode)
    (should (string-match-p "动态开" (crosslang-hydra-title)))
    (crosslang-hydra-test--head "SPC")
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-hydra-close-mode-cleans-up-and-restores-key ()
  (crosslang-hydra-test--with
    (crosslang-live-mode 1)
    (hydra-crosslang/body)
    (crosslang-hydra-test--head "o")
    (should-not crosslang-mode)
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)
    (should-not hydra-curr-map)
    (should (eq (key-binding (kbd "M--")) (global-key-binding (kbd "M--"))))))

(ert-deftest crosslang-hydra-cancels-proposal-only-on-c ()
  (crosslang-hydra-test--with
    (setq crosslang--proposal '(:text "sentinel"))
    (crosslang-hydra-test--head "c")
    (should-not crosslang--proposal)))

(ert-deftest crosslang-hydra-title-reflects-current-buffer ()
  (crosslang-hydra-test--with
    (setq-local crosslang-assistance 'partial)
    (setq crosslang--review '(review))
    (should (string-match-p "partial.*动态关.*无提示观察中" (crosslang-hydra-title)))))

(ert-deftest crosslang-hydra-core-reload-preserves-menu-binding ()
  (load "crosslang" nil t)
  (should-not (lookup-key crosslang-mode-map (kbd "M--")))
  (should (eq (lookup-key revolt-map (kbd "-")) 'hydra-crosslang/body)))

(ert-deftest crosslang-hydra-help-opens-the-menu ()
  (crosslang-hydra-test--with
    (crosslang-key-help)
    (should (eq hydra-curr-body-fn 'hydra-crosslang/body))
    (crosslang-hydra-test--head "?")
    (should (eq hydra-curr-body-fn 'hydra-crosslang/body))))

;;; crosslang-hydra-tests.el ends here

(ert-deftest crosslang-leader-preserves-neighbours-and-refuses-conflict ()
  (let ((revolt-map (make-sparse-keymap)))
    (define-key revolt-map (kbd "p") #'ignore)
    (crosslang-leader-install)
    (should (eq (lookup-key revolt-map (kbd "p")) 'ignore))
    (should (eq (lookup-key revolt-map (kbd "-")) 'hydra-crosslang/body))
    (crosslang-leader-install)
    (define-key revolt-map (kbd "-") #'ignore)
    (should-error (crosslang-leader-install) :type 'user-error)
    (should (eq (lookup-key revolt-map (kbd "-")) 'ignore))))

(ert-deftest crosslang-hydra-mode-can-toggle-from-global-menu ()
  (crosslang-hydra-test--with
    (crosslang-mode -1)
    (hydra-crosslang/body)
    (should-not crosslang-mode)
    (crosslang-hydra-test--head "m")
    (should crosslang-mode)
    (crosslang-hydra-test--head "m")
    (should-not crosslang-mode)
    (should (eq (lookup-key revolt-map (kbd "-")) 'hydra-crosslang/body))))

(ert-deftest crosslang-hydra-pair-writing-is-explicit-and-toggleable ()
  (crosslang-hydra-test--with
    (should-not (bound-and-true-p crosslang-pair-mode))
    (crosslang-hydra-test--head "w")
    (should crosslang-pair-mode)
    (should crosslang-live-mode)
    (should (string-match-p "正文自动维护" (crosslang-hydra-title)))
    (crosslang-hydra-test--head "w")
    (should-not crosslang-pair-mode)
    (should-not crosslang-live-mode)))
