;;; crosslang-bidirectional-tests.el --- Automatic request language -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang-live)

(ert-deftest crosslang-bidirectional-detection-is-explicit-and-bounded ()
  (dolist (pair '(("请核对交付日期。" . "en") ("Please check the date." . "zh")
                  ("Please check 交付日期 50 USD." . "en") ("API" . "zh")
                  (" 123!?\n" . nil) ("" . nil)))
    (should (equal (crosslang-live--target (car pair)) (cdr pair)))))

(defmacro crosslang-bidirectional-test--english (&rest body)
  `(with-temp-buffer
     (fundamental-mode) (buffer-enable-undo)
     (insert "Other line.\nPlease check the delivery date.")
     (let ((requests 0) request (source (buffer-string)))
       (setq-local crosslang-provider
                   (list :operations '(express)
                         :start (lambda (sent done)
                                  (setq requests (1+ requests) request sent)
                                  (funcall done '(:text "请核对交付日期。")) nil)))
       (unwind-protect
           (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                     ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
             (crosslang-live-mode 1)
             (cancel-timer crosslang-live--timer)
             (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick))
             ,@body)
         (crosslang-mode -1)))))

(ert-deftest crosslang-bidirectional-english-uses-chinese-and-complete-source ()
  (crosslang-bidirectional-test--english
    (should (= requests 1))
    (should (equal (plist-get request :target) "zh"))
    (should-not (plist-get request :spans))
    (should (equal (plist-get request :text) "Please check the delivery date."))
    (should (equal (plist-get crosslang--proposal :target) "zh"))
    (should (equal source (buffer-string)))
    (should (equal crosslang-target-language "en"))
    (should-not (plist-get (plist-get crosslang--proposal :response) :uncertain))))

(ert-deftest crosslang-bidirectional-english-bilingual-write-and-undo ()
  (crosslang-bidirectional-test--english
    (setq buffer-undo-list nil)
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t)))
      (crosslang-insert-bilingual))
    (should (equal (buffer-string) (concat source "\n请核对交付日期。")))
    (should (= requests 1))
    (should-not crosslang-live--timer)
    (undo-only 1) (should (equal source (buffer-string)))))

(ert-deftest crosslang-bidirectional-english-replacement-and-details ()
  (crosslang-bidirectional-test--english
    (crosslang-show-details)
    (with-current-buffer crosslang--preview
      (should (string-match-p "英→中" (buffer-string))))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-accept))
    (should (equal (buffer-string) "Other line.\n请核对交付日期。"))
    (should (= requests 1))))

(ert-deftest crosslang-bidirectional-numbers-alone-do-not-request ()
  (with-temp-buffer
    (fundamental-mode) (insert "1234 !!")
    (setq-local crosslang-provider (list :operations '(express) :start (lambda (&rest _) (ert-fail "No language"))))
    (unwind-protect
        (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                  ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
          (crosslang-live-mode 1)
          (should-not (crosslang-live--ready-bounds)))
      (crosslang-mode -1))))
