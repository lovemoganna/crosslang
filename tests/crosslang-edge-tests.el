;;; crosslang-edge-tests.el --- User-flow regressions -*- lexical-binding: t; -*-
(require 'crosslang-tests)

(ert-deftest crosslang-disabled-during-confirmation-must-not-apply ()
  (crosslang-test--draft
   (let ((before (buffer-string)))
     (crosslang-test--candidate)
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (&rest _) (crosslang-mode -1) t)))
       (should-error (crosslang-accept) :type 'user-error))
     (should (equal before (buffer-string))))))

(ert-deftest crosslang-dismissed-during-confirmation-must-not-apply ()
  (crosslang-test--draft
   (let ((before (buffer-string)))
     (crosslang-test--candidate)
     (cl-letf (((symbol-function 'yes-or-no-p)
                (lambda (&rest _) (crosslang-dismiss) t)))
       (should-error (crosslang-accept) :type 'user-error))
     (should (equal before (buffer-string))))))

(ert-deftest crosslang-narrowed-history-is-not-current-draft ()
  (require 'gptel)
  (with-temp-buffer
    (org-mode) (gptel-mode 1)
    (insert (gptel-prompt-prefix-string) "old already sent message")
    (let ((historical-end (point)))
      (insert "\n\n" (propertize "Agent reply" 'gptel 'response)
              "\n\n" (gptel-prompt-prefix-string) "current draft")
      (narrow-to-region (point-min) historical-end)
      (should-error (crosslang-gptel--bounds) :type 'user-error))
    (gptel-mode -1)))

(ert-deftest crosslang-preview-accept-key-with-real-evil ()
  (require 'evil)
  (let ((was-enabled evil-mode))
    (unwind-protect
        (progn
          (evil-mode 1)
          (crosslang-test--draft
           (crosslang-test--candidate)
           (with-current-buffer crosslang--preview
             (evil-initialize)
             (should (eq (key-binding (kbd "a")) 'crosslang-accept))
             (should (eq (key-binding (kbd "q")) 'crosslang-dismiss)))))
      (unless was-enabled (evil-mode -1)))))

(ert-deftest crosslang-preview-delete-does-not-leave-candidate ()
  (crosslang-test--draft
   (crosslang-test--candidate)
   (kill-buffer crosslang--preview)
   (should-not crosslang--proposal)))

(ert-deftest crosslang-dismiss-preserves-current-buffer-and-kills-only-preview ()
  (crosslang-test--draft
   (let ((origin (current-buffer)) (text (buffer-string)))
     (crosslang-test--candidate)
     (let ((preview crosslang--preview))
       (crosslang-dismiss)
       (should (eq origin (current-buffer)))
       (should (buffer-live-p origin))
       (should-not (buffer-live-p preview))
       (should (equal text (buffer-string)))))))

(ert-deftest crosslang-timeout-cancels-without-touching-draft ()
  (crosslang-test--draft
   (let ((crosslang-timeout 0.02) cancelled
         (original (buffer-string)))
     (setq-local crosslang-provider
                 (list :operations '(express)
                       :start (lambda (_request _done) (lambda () (setq cancelled t)))))
     (crosslang-express)
     (let ((deadline (+ (float-time) 1)))
       (while (and crosslang--timer (< (float-time) deadline))
         (accept-process-output nil 0.01)))
     (should cancelled)
     (should-not crosslang--timer)
     (should-not crosslang--preview)
     (should (equal original (buffer-string))))))
