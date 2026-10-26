;;; crosslang-bilingual-tests.el --- Durable bilingual draft insertion -*- lexical-binding: t; -*-
(require 'ert)
(require 'cl-lib)
(require 'crosslang-org)
(require 'crosslang-gptel)

(defmacro crosslang-bilingual-test--with (&rest body)
  `(with-temp-buffer
     (org-mode) (buffer-enable-undo)
     (insert "前一段。\n\nPlease check 交付日期.\n\n后一段。")
     (goto-char (point-min)) (search-forward "交付日期")
     (crosslang-mode 1)
     (let ((calls 0) (confirmations 0))
       (setq-local crosslang-provider
                   (list :operations '(express)
                         :start (lambda (_request done)
                                  (setq calls (1+ calls))
                                  (funcall done '(:text "Please check delivery date."
                                                 :edits ((:start 13 :end 17 :text "delivery date")))) nil)))
       (unwind-protect (progn (crosslang-express) ,@body)
         (crosslang-mode -1)))))

(ert-deftest crosslang-bilingual-retains-source-neighbours-and-single-undo ()
  (crosslang-bilingual-test--with
    (let ((original (buffer-string)))
      (setq buffer-undo-list nil)
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (prompt) (should (string-match-p "保留原文" prompt))
                   (setq confirmations (1+ confirmations)) t)))
        (crosslang-insert-bilingual))
      (should (equal (buffer-string)
                     "前一段。\n\nPlease check 交付日期.\nPlease check delivery date.\n\n后一段。"))
      (should (= calls 1)) (should (= confirmations 1))
      (should-not crosslang--proposal) (should-not crosslang--overlays)
      (undo-only 1)
      (should (equal original (buffer-string))))))

(ert-deftest crosslang-bilingual-declining-keeps-source-and-candidate ()
  (crosslang-bilingual-test--with
    (let ((original (buffer-string)) (proposal crosslang--proposal))
      (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) nil)))
        (should-error (crosslang-insert-bilingual) :type 'user-error))
      (should (equal original (buffer-string)))
      (should (eq proposal crosslang--proposal))
      (should (= calls 1)))))

(ert-deftest crosslang-bilingual-no-candidate-does-not-request ()
  (with-temp-buffer
    (org-mode) (crosslang-mode 1)
    (unwind-protect
        (cl-letf (((symbol-function 'crosslang--request) (lambda (&rest _) (ert-fail "New request"))))
          (should-error (crosslang-insert-bilingual) :type 'user-error))
      (crosslang-mode -1))))

(ert-deftest crosslang-bilingual-blocked-meaning-never-confirms ()
  (dolist (response '((:text "Please check 500 USD.")
                      (:text "Maybe?" :uncertain t)))
    (crosslang-bilingual-test--with
      (let ((original (buffer-string)))
        (setq crosslang--proposal (plist-put crosslang--proposal :response response))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Unsafe confirmation"))))
          (should-error (crosslang-insert-bilingual) :type 'user-error))
        (should (equal original (buffer-string)))))))

(ert-deftest crosslang-bilingual-stale-and-readonly-are-rejected ()
  (crosslang-bilingual-test--with
    (let ((buffer-read-only t))
      (should-error (crosslang-insert-bilingual) :type 'user-error))
    (goto-char (point-max)) (insert "changed")
    (should-error (crosslang-insert-bilingual) :type 'user-error)))

(ert-deftest crosslang-bilingual-rechecks-after-confirmation ()
  (crosslang-bilingual-test--with
    (let ((original (buffer-string)))
      (cl-letf (((symbol-function 'yes-or-no-p)
                 (lambda (&rest _) (crosslang-dismiss) t)))
        (should-error (crosslang-insert-bilingual) :type 'user-error))
      (should (equal original (buffer-string))))))

(ert-deftest crosslang-bilingual-reading-result-cannot-write ()
  (crosslang-bilingual-test--with
    (setq crosslang--proposal (plist-put crosslang--proposal :operation 'translate))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Reading write"))))
      (should-error (crosslang-insert-bilingual) :type 'user-error))))

(ert-deftest crosslang-bilingual-long-candidate-requires-review ()
  (crosslang-bilingual-test--with
    (setq crosslang--proposal (plist-put crosslang--proposal :response (list :text (make-string 200 ?a))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Unseen result"))))
      (let ((err (should-error (crosslang-insert-bilingual) :type 'user-error)))
        (should (string-match-p "SPC - b" (error-message-string err)))))
    (should (buffer-live-p crosslang--preview))))

(ert-deftest crosslang-bilingual-old-accept-still-replaces-only ()
  (crosslang-bilingual-test--with
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-accept))
    (should (equal (buffer-string) "前一段。\n\nPlease check delivery date.\n\n后一段。"))))

(ert-deftest crosslang-bilingual-repeat-cannot-duplicate ()
  (crosslang-bilingual-test--with
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-insert-bilingual))
    (let ((written (buffer-string)))
      (should-error (crosslang-insert-bilingual) :type 'user-error)
      (should (equal written (buffer-string))))))

(ert-deftest crosslang-bilingual-preview-key-writes-to-origin ()
  (crosslang-bilingual-test--with
    (let ((origin (current-buffer)))
      (crosslang-show-details)
      (with-current-buffer crosslang--preview
        (should (eq (key-binding (kbd "b")) 'crosslang-insert-bilingual))
        (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
          (crosslang-insert-bilingual)))
      (with-current-buffer origin
        (should (string-match-p "交付日期.\nPlease check delivery date" (buffer-string)))
        (should-not crosslang--preview)))))

(ert-deftest crosslang-bilingual-gptel-appends-only-to-final-draft ()
  (require 'gptel)
  (with-temp-buffer
    (org-mode)
    ;; Use the actual adapter without running personal gptel setup/save hooks.
    (setq-local gptel-mode t)
    (let ((history (propertize "Agent response\n" 'gptel 'response)))
      (insert history (gptel-prompt-prefix-string) "交付日期")
      (crosslang-mode 1)
      (unwind-protect
          (progn
            (setq-local crosslang-provider
                        (list :operations '(express)
                              :start (lambda (_request done)
                                       (funcall done '(:text "delivery date" :edits ((:start 0 :end 4 :text "delivery date")))) nil)))
            (crosslang-express)
            (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))
                      ((symbol-function 'gptel-send) (lambda (&rest _) (ert-fail "Unexpected send"))))
              (crosslang-insert-bilingual))
            (should (equal (buffer-substring (point-min) (+ (point-min) (length history))) history))
            (should (equal (buffer-substring-no-properties (car (crosslang--bounds)) (point-max))
                           "交付日期\ndelivery date")))
        (crosslang-mode -1)
        (setq-local gptel-mode nil)))))
