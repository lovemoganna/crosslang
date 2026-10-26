;;; crosslang-tests.el --- Contract and real resource tests -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang)
(require 'crosslang-local)
(require 'crosslang-gptel)

(defmacro crosslang-test--draft (&rest body)
  `(with-temp-buffer
     (buffer-enable-undo)
     (insert "不要超过 50 USD; keep the deadline.")
     (let ((crosslang-presentation 'buffer)
           (crosslang-assistance 'full)
           (crosslang-adapters (list (cons (lambda () t)
                                         (lambda () (cons (point-min) (point-max)))))))
       (crosslang-mode 1)
       (unwind-protect (progn ,@body) (crosslang-mode -1)))))

(defun crosslang-test--candidate (&optional uncertain)
  (setq-local crosslang-provider
              (list :operations '(express explain translate)
                    :start (lambda (request done)
                             (let ((text (plist-get request :text)) edits)
                               (dolist (span (reverse (copy-sequence (plist-get request :spans))))
                                 (let ((start (plist-get span :start)) (end (plist-get span :end)))
                                   (push (list :start start :end end :text "Only") edits)
                                   (setq text (concat (substring text 0 start) "Only" (substring text end)))))
                               (funcall done (list :text (if edits text "Do not exceed 50 USD; keep the deadline.")
                                                   :edits edits :uncertain uncertain))) nil)))
  (crosslang-express))

(ert-deftest crosslang-no-changes-without-confirmation ()
  (crosslang-test--draft
   (let ((text (buffer-string)) (undo buffer-undo-list))
     (crosslang-test--candidate)
     (should (equal text (buffer-string)))
     (should (equal undo buffer-undo-list))
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
       (should-error (crosslang-accept) :type 'user-error))
     (should (equal text (buffer-string))))))

(ert-deftest crosslang-accept-and-native-undo ()
  (crosslang-test--draft
   (let ((text (buffer-string)))
     (setq buffer-undo-list nil)
     (crosslang-test--candidate)
     (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-accept))
     (should (string-prefix-p "Do not" (buffer-string)))
     (undo-only 1)
     (should (equal text (buffer-string))))))

(ert-deftest crosslang-stale-result-rejected ()
  (crosslang-test--draft
   (crosslang-test--candidate)
   (insert " edited")
   (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Must not ask"))))
     (should-error (crosslang-accept) :type 'user-error))))

(ert-deftest crosslang-confirmation-race-rejected ()
  (crosslang-test--draft
   (crosslang-test--candidate)
   (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (insert "arrived") t)))
     (should-error (crosslang-accept) :type 'user-error))
   (should-not (string-prefix-p "Do not" (buffer-string)))))

(ert-deftest crosslang-ambiguity-blocks-acceptance ()
  (crosslang-test--draft
   (crosslang-test--candidate t)
   (should-error (crosslang-accept) :type 'user-error)))

(ert-deftest crosslang-disable-cancels-and-ignores-late-result ()
  (crosslang-test--draft
   (let (callback cancelled)
     (setq-local crosslang-provider
                 (list :operations '(express)
                       :start (lambda (_request done) (setq callback done)
                                (lambda () (setq cancelled t)))))
     (crosslang-express)
     (crosslang-mode -1)
     (should cancelled)
     (funcall callback '(:text "late"))
     (should-not crosslang--preview)
     (should-not crosslang--timer))))

(ert-deftest crosslang-new-request-invalidates-old-result ()
  (crosslang-test--draft
   (let (callbacks)
     (setq-local crosslang-provider
                 (list :operations '(express)
                       :start (lambda (_request done) (push done callbacks) nil)))
     (crosslang-express) (crosslang-express)
     (funcall (cadr callbacks) '(:text "stale"))
     (should-not crosslang--preview)
     (funcall (car callbacks) '(:text "current"))
     (should (equal "current" (plist-get (plist-get crosslang--proposal :response) :text))))))

(ert-deftest crosslang-missing-capability-retains-original ()
  (crosslang-test--draft
   (setq-local crosslang-provider nil)
   (let ((text (buffer-string)))
     (should-error (crosslang-express) :type 'user-error)
     (should (equal text (buffer-string))))))

(ert-deftest crosslang-reading-result-cannot-replace-message ()
  (crosslang-test--draft
   (crosslang-test--candidate)
   (crosslang--request 'translate (cons (point-min) (point-max)))
   (should-error (crosslang-accept) :type 'user-error)))

(ert-deftest crosslang-mode-preserves-undo-and-edit-hooks ()
  (with-temp-buffer
    (buffer-enable-undo) (insert "existing")
    (let ((undo buffer-undo-list) (text (buffer-string))
          (hooks after-change-functions) (ret (key-binding (kbd "RET")))
          (windows (current-window-configuration)))
      (crosslang-mode 1) (crosslang-mode -1)
      (should (equal undo buffer-undo-list))
      (should (equal text (buffer-string)))
      (should (equal hooks after-change-functions))
      (should (eq ret (key-binding (kbd "RET"))))
      (should (compare-window-configurations windows (current-window-configuration))))))

(ert-deftest crosslang-numeric-and-negation-hints ()
  (should (= 3 (length (crosslang--review-flags "不得超过 50 USD" "Exceed 500 USD"))))
  (should (equal '("50") (crosslang--numbers "50 USD"))))

(ert-deftest crosslang-partial-only-replaces-selection ()
  (crosslang-test--draft
   (setq-local crosslang-assistance 'partial)
   (should-error (crosslang-express) :type 'user-error)
   (goto-char (point-min)) (set-mark (point)) (forward-char 2)
   (let ((transient-mark-mode t) (mark-active t))
     (crosslang-test--candidate)
     (should (= 2 (- (plist-get crosslang--proposal :end)
                     (plist-get crosslang--proposal :start)))))))

(ert-deftest crosslang-real-dictionary-async ()
  (let ((crosslang-local-dictionaries
         (or (getenv "CROSSLANG_TEST_DICTIONARY") (ert-skip "Use scripts/run_tests.py to generate a temporary dictionary")))
        (crosslang-local-model nil) response cancel
        (start (float-time)))
    (unwind-protect
        (progn
          (setq cancel (crosslang-local--start
                        '(:operation explain :text "hello" :target "zh" :assistance on-demand)
                        (lambda (value) (setq response value))))
          (should (< (- (float-time) start) 0.2))
          (let ((deadline (+ (float-time) 10)))
            (while (and (not response) (< (float-time) deadline))
              (accept-process-output nil 0.02)))
          (should-not (plist-get response :error))
          (should (string-match-p "喂" (plist-get response :text))))
      (when cancel (funcall cancel)))))

(ert-deftest crosslang-real-gptel-draft-boundary ()
  (require 'gptel)
  (with-temp-buffer
    (org-mode) (gptel-mode 1)
    (let* ((prefix (gptel-prompt-prefix-string)) (ret (key-binding (kbd "RET"))))
      (insert prefix "previous question\n\n")
      (insert (propertize "English reply.\n" 'gptel 'response))
      (insert prefix "限制是 50 USD; keep this.")
      (let ((draft (crosslang-gptel--bounds)))
        (should (equal "限制是 50 USD; keep this."
                       (buffer-substring-no-properties (car draft) (cdr draft)))))
      (crosslang-mode 1)
      (should (eq ret (key-binding (kbd "RET")))))
    (crosslang-mode -1) (gptel-mode -1)))

(ert-deftest crosslang-real-gptel-response-not-draft ()
  (require 'gptel)
  (with-temp-buffer
    (org-mode) (gptel-mode 1)
    (insert (gptel-prompt-prefix-string) "previous question\n\n")
    (insert (propertize "Agent reply" 'gptel 'response))
    (should-error (crosslang-gptel--bounds) :type 'user-error)
    (gptel-mode -1)))

(provide 'crosslang-tests)
