;;; crosslang-all-modes-tests.el --- Generic editable input scope -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang-live)

(defmacro crosslang-all-modes-test--with (mode &rest body)
  `(with-temp-buffer
     (funcall ,mode)
     (setq buffer-read-only nil)
     (insert "上一行隐私\n交付日期\n下一行隐私")
     (goto-char (point-min)) (forward-line 1) (end-of-line)
     (let ((calls 0) submitted)
       (setq-local crosslang-provider
                   (list :operations '(express)
                         :start (lambda (request done)
                                  (setq calls (1+ calls) submitted request)
                                  (funcall done '(:text "delivery date" :edits ((:start 0 :end 4 :text "delivery date")))) nil)))
       (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                 ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
         (unwind-protect (progn (crosslang-live-mode 1) ,@body)
           (crosslang-mode -1))))))

(defun crosslang-all-modes-test--fire ()
  (cancel-timer crosslang-live--timer)
  (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))

(ert-deftest crosslang-all-modes-no-mode-whitelist-current-line-only ()
  (dolist (mode '(fundamental-mode text-mode emacs-lisp-mode lisp-interaction-mode special-mode))
    (crosslang-all-modes-test--with mode
      (crosslang-all-modes-test--fire)
      (should (= calls 1))
      (should (equal (plist-get submitted :text) "交付日期"))
      (should-not (plist-get submitted :context))
      (should crosslang--proposal))))

(ert-deftest crosslang-all-modes-bilingual-and-undo-stay-on-current-line ()
  (crosslang-all-modes-test--with #'fundamental-mode
    (buffer-enable-undo)
    (crosslang-all-modes-test--fire)
    (setq buffer-undo-list nil)
    (let ((source (buffer-string)))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-insert-bilingual))
      (should (equal (buffer-string) "上一行隐私\n交付日期\ndelivery date\n下一行隐私"))
      (should-not crosslang-live--timer)
      (should (= calls 1))
      (undo-only 1) (should (equal source (buffer-string))))))

(ert-deftest crosslang-all-modes-readonly-buffer-rejected ()
  (with-temp-buffer
    (special-mode)
    (should-error (crosslang-live-mode 1) :type 'user-error)
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-all-modes-readonly-line-is-not-submitted ()
  (crosslang-all-modes-test--with #'fundamental-mode
    (put-text-property (line-beginning-position) (line-end-position) 'read-only t)
    (crosslang-all-modes-test--fire)
    (should (= calls 0))
    (should-not crosslang--proposal)))

(ert-deftest crosslang-all-modes-readonly-prompt-is-excluded ()
  (crosslang-all-modes-test--with #'fundamental-mode
    (goto-char (line-beginning-position))
    (insert (propertize "PROMPT> " 'read-only t 'rear-nonsticky t))
    (end-of-line)
    (crosslang-all-modes-test--fire)
    (should (equal (plist-get submitted :text) "交付日期"))))

(ert-deftest crosslang-all-modes-process-mark-excludes-transcript ()
  (crosslang-all-modes-test--with #'fundamental-mode
    (let ((mark (copy-marker (- (point) 4))))
      (cl-letf (((symbol-function 'get-buffer-process) (lambda (&rest _) 'test-process))
                ((symbol-function 'process-mark) (lambda (&rest _) mark)))
        (crosslang-all-modes-test--fire)
        (should (equal (plist-get submitted :text) "交付日期"))
        (crosslang-dismiss)
        (goto-char (point-min))
        (should-error (crosslang--editable-line-bounds) :type 'user-error))
      (set-marker mark nil))))

(ert-deftest crosslang-all-modes-selection-and-oversize-still-pause ()
  (crosslang-all-modes-test--with #'fundamental-mode
    (let ((transient-mark-mode t))
      (set-mark (line-beginning-position)) (setq mark-active t)
      (crosslang-all-modes-test--fire) (should (= calls 0)))
    (setq mark-active nil)
    (let ((crosslang-live-max-characters 2))
      (crosslang-live--queue) (crosslang-all-modes-test--fire)
      (should (= calls 0)))))
