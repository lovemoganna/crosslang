;;; crosslang-org-tests.el --- Org prose and model failure regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'org)
(require 'crosslang-live)
(require 'crosslang-org nil t)

(ert-deftest crosslang-org-live-in-ordinary-org-without-gptel ()
  (with-temp-buffer
    (org-mode) (insert "* Topic\n\nPlease check 交付日期.\n\nOther paragraph stays.\n")
    (search-backward "交付日期")
    (crosslang-mode 1)
    (unwind-protect
        (progn
          (crosslang-live-mode 1)
          (should-not (bound-and-true-p gptel-mode))
          (should crosslang-live-mode)
          (should (equal "Please check 交付日期."
                         (let ((bounds (crosslang--bounds)))
                           (buffer-substring-no-properties (car bounds) (cdr bounds))))))
      (crosslang-live-mode -1) (crosslang-mode -1))))

(ert-deftest crosslang-org-manual-expression-reads-only-current-paragraph ()
  (with-temp-buffer
    (org-mode) (insert "#+title: private title\n* Section\n\nPrevious private prose.\n\n请检查交付日期。\n\nFollowing private prose.\n")
    (search-backward "请检查") (crosslang-mode 1)
    (let (sent)
      (setq-local crosslang-provider (list :operations '(express) :start (lambda (request _) (setq sent request) nil)))
      (crosslang-express)
      (should (equal "请检查交付日期。" (plist-get sent :text)))
      (should-not (plist-get sent :context)))
    (crosslang-mode -1)))

(ert-deftest crosslang-org-newline-after-prose-keeps-line-break-outside-request ()
  (with-temp-buffer
    (org-mode) (insert "请检查交付日期。\n")
    (let ((bounds (crosslang-org--bounds)))
      (should (equal "请检查交付日期。" (buffer-substring-no-properties (car bounds) (cdr bounds)))))
    (should (= (char-before) ?\n))))

(ert-deftest crosslang-org-no-model-turns-off-live-without-source-change ()
  (with-temp-buffer
    (org-mode) (insert "你好") (crosslang-mode 1)
    (let ((source (buffer-string)))
      (setq-local crosslang-provider
                  (list :operations '(express)
                        :start (lambda (_ done) (funcall done '(:error "No local text model is loaded" :error_code "model-not-loaded")) nil)))
      (crosslang-live-mode 1)
      (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
        (when (timerp crosslang-live--timer) (cancel-timer crosslang-live--timer))
        (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))
      (should-not crosslang-live-mode)
      (should-not crosslang-live--timer)
      (should (equal source (buffer-string)))
      (should crosslang-mode))
    (crosslang-mode -1)))

(ert-deftest crosslang-org-protected-structures-are-not-expression-targets ()
  (dolist (sample '("#+begin_src emacs-lisp\n(message \"你好\")\n#+end_src\n"
                    "#+begin_example\n你好\n#+end_example\n"
                    "* 你好\n" "#+title: 你好\n" "| 你好 |\n"
                    "* H\n:PROPERTIES:\n:ID: 你好\n:END:\n"
                    "# 你好\n"))
    (with-temp-buffer
      (org-mode) (insert sample) (search-backward "你好") (crosslang-mode 1)
      (should-error (crosslang-express) :type 'user-error)
      (crosslang-mode -1))))

(ert-deftest crosslang-org-gptel-still-uses-conversation-adapter ()
  (require 'gptel)
  (with-temp-buffer
    (org-mode) (gptel-mode 1) (insert (gptel-prompt-prefix-string) "你好")
    (should (eq (cdr (crosslang--adapter)) 'crosslang-gptel--bounds))
    (gptel-mode -1)))

(ert-deftest crosslang-org-resource-error-has-actionable-message ()
  (should (string-match-p "Bionic" (crosslang--format-error '(:error "raw" :error_code "model-not-loaded"))))
  (should-not (string-match-p "ValueError" (crosslang--format-error '(:error "ValueError: raw" :error_code "model-not-loaded")))))

(ert-deftest crosslang-org-explicit-selected-code-retains-manual-workflow ()
  (with-temp-buffer
    (org-mode) (insert "#+begin_src emacs-lisp\n(message \"你好\")\n#+end_src\n")
    (search-backward "你好") (set-mark (point)) (forward-char 2)
    (let ((transient-mark-mode t) (mark-active t) sent)
      (crosslang-mode 1)
      (setq-local crosslang-provider (list :operations '(express) :start (lambda (request _) (setq sent request) nil)))
      (crosslang-express)
      (should (equal "你好" (plist-get sent :text)))
      (crosslang-mode -1))))

(ert-deftest crosslang-org-english-selection-still-explained-by-smart-command ()
  (with-temp-buffer
    (org-mode) (insert "The bank approved it.") (goto-char 5) (set-mark (point)) (forward-char 4)
    (let ((transient-mark-mode t) (mark-active t) sent)
      (crosslang-mode 1)
      (setq-local crosslang-provider (list :operations '(explain express) :start (lambda (request _) (setq sent request) nil)))
      (crosslang-dwim)
      (should (eq (plist-get sent :operation) 'explain))
      (crosslang-mode -1))))

(ert-deftest crosslang-org-async-resource-error-stops-owned-request ()
  (with-temp-buffer
    (org-mode) (insert "你好") (crosslang-mode 1)
    (let (callback)
      (setq-local crosslang-provider (list :operations '(express) :start (lambda (_ done) (setq callback done) nil)))
      (crosslang-live-mode 1)
      (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
        (when (timerp crosslang-live--timer) (cancel-timer crosslang-live--timer))
        (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))
      (should crosslang-live--owned-generation)
      (funcall callback '(:error "offline" :error_code "service-unavailable"))
      (should-not crosslang-live-mode)
      (should-not crosslang--timer)
      (should-not (memq #'crosslang-live--resource-error crosslang-error-functions)))
    (crosslang-mode -1)))
