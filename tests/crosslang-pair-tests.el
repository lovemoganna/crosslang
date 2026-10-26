;;; crosslang-pair-tests.el --- Explicit automatic body ownership -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang-pair)

(defmacro crosslang-pair-test--with (&rest body)
  `(with-temp-buffer
     (fundamental-mode) (buffer-enable-undo)
     (insert "日期\nFollowing line.") (goto-char 3)
     (let ((calls 0) requests response)
       (setq-local crosslang-provider
                   (list :operations '(express)
                         :start (lambda (request done)
                                  (setq calls (1+ calls)) (push request requests)
                                  (let* ((span (car (plist-get request :spans)))
                                         (translation (if (string-match-p "更新" (plist-get request :text)) "updated date" "date")))
                                    (funcall done (or response (list :text translation :edits
                                       (list (list :start (plist-get span :start) :end (plist-get span :end) :text translation)))))) nil)))
       (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                 ((symbol-function 'crosslang-live--composing-p) (lambda () nil))
                 ((symbol-function 'yes-or-no-p) (lambda (&rest _) (ert-fail "Pair mode must not ask every write"))))
         (unwind-protect (progn (crosslang-pair-mode 1) ,@body)
           (crosslang-pair-mode -1) (when crosslang-mode (crosslang-mode -1)))))))

(defun crosslang-pair-test--fire ()
  (when (timerp crosslang-live--timer) (cancel-timer crosslang-live--timer))
  (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))

(ert-deftest crosslang-pair-first-write-keeps-source-caret-and-neighbour ()
  (crosslang-pair-test--with
    (should (= calls 0))
    (crosslang-pair-test--fire)
    (should (= calls 1))
    (should (equal (buffer-string) "日期\ndate\nFollowing line."))
    (should (= (point) 3))
    (should (equal (plist-get (car requests) :text) "日期"))
    (should-not crosslang--proposal)
    (should-not crosslang-live--timer)
    (should-not crosslang-pair--stale)))

(ert-deftest crosslang-pair-edit-source-refreshes-only-owned-english ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (insert "更新")
    (should crosslang-pair-mode)
    (should crosslang-pair--stale)
    (should (timerp crosslang-live--timer))
    (crosslang-pair-test--fire)
    (should (= calls 2))
    (should (equal (buffer-string) "日期更新\nupdated date\nFollowing line."))
    (should (= (point) 5))
    (should (equal (plist-get (car requests) :text) "日期更新"))
    (crosslang-live--queue)
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-pair-manual-target-edit-stops-without-overwriting ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (goto-char (car crosslang-pair--target)) (insert "my ")
    (should-not crosslang-pair-mode)
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)
    (should (equal (buffer-string) "日期\nmy date\nFollowing line."))
    (should (= calls 1))))

(ert-deftest crosslang-pair-disabling-keeps-both-body-languages ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (let ((text (buffer-string)))
      (crosslang-pair-mode -1)
      (should (equal text (buffer-string)))
      (should-not crosslang-live-mode)
      (should-not crosslang-live-bounds-function)
      (should-not crosslang-pair--source))))

(ert-deftest crosslang-pair-uncertain-never-autowrites ()
  (crosslang-pair-test--with
    (setq response '(:text "Which date?" :uncertain t))
    (crosslang-pair-test--fire)
    (should (equal (buffer-string) "日期\nFollowing line."))
    (should-not crosslang-pair--target)
    (should (eq crosslang--ui-status 'uncertain))))

(ert-deftest crosslang-pair-unsafe-numbers-never-autowrite ()
  (crosslang-pair-test--with
    (setq response '(:text "date 500" :edits ((:start 0 :end 2 :text "date 500"))))
    (crosslang-pair-test--fire)
    (should (equal (buffer-string) "日期\nFollowing line."))
    (should-not crosslang-pair--target)
    (should (eq crosslang--ui-status 'blocked))))

(ert-deftest crosslang-pair-undo-stops-so-it-does-not-silently-redo ()
  (crosslang-pair-test--with
    (setq buffer-undo-list nil)
    (crosslang-pair-test--fire)
    (undo-only 1)
    (should (equal (buffer-string) "日期\nFollowing line."))
    (should-not crosslang-pair-mode)
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-pair-outside-source-does-not-trigger-other-line ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (goto-char (point-max)) (insert "新内容")
    (crosslang-pair-test--fire)
    (should (= calls 1))
    (should (string-suffix-p "Following line.新内容" (buffer-string)))))

(ert-deftest crosslang-pair-parent-mode-off-cleans-up-ownership ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (let ((text (buffer-string)))
      (crosslang-mode -1)
      (should-not crosslang-pair-mode)
      (should-not crosslang-live-mode)
      (should (equal text (buffer-string))))))

(ert-deftest crosslang-pair-stale-async-result-cannot-write ()
  (crosslang-pair-test--with
    (let (callbacks (cancelled 0))
      (setq-local crosslang-provider
                  (list :operations '(express)
                        :start (lambda (_request done) (push done callbacks)
                                 (lambda () (setq cancelled (1+ cancelled))))))
      (crosslang-pair-test--fire)
      (insert "更新")
      (crosslang-pair-test--fire)
      (should (= cancelled 1))
      (funcall (cadr callbacks) '(:text "old date" :edits ((:start 0 :end 2 :text "old date"))))
      (should-not crosslang-pair--target)
      (funcall (car callbacks) '(:text "updated date" :edits ((:start 0 :end 4 :text "updated date"))))
      (should (equal (buffer-string) "日期更新\nupdated date\nFollowing line.")))))

(ert-deftest crosslang-pair-untracked-target-change-is-also-rejected ()
  (crosslang-pair-test--with
    (crosslang-pair-test--fire)
    (let ((inhibit-modification-hooks t))
      (save-excursion (goto-char (car crosslang-pair--target)) (insert "manual ")))
    (insert "更新")
    (crosslang-pair-test--fire)
    (should (equal (buffer-string) "日期更新\nmanual date\nFollowing line."))))

(ert-deftest crosslang-pair-reverse-direction-keeps-english-source ()
  (crosslang-pair-test--with
    (erase-buffer) (insert "Hello")
    (setq response '(:text "你好"))
    (crosslang-pair-test--fire)
    (should (equal (buffer-string) "Hello\n你好"))
    (should (equal (plist-get (car requests) :target) "zh"))))
