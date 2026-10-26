;;; crosslang-live-tests.el --- Scheduling and lifecycle regressions -*- lexical-binding: t; -*-
(require 'ert)
(require 'gptel)
(require 'crosslang-live)

(defmacro crosslang-live-test--with (&rest body)
  `(with-temp-buffer
     (org-mode) (gptel-mode 1) (insert (gptel-prompt-prefix-string) "请检查")
     (crosslang-mode 1)
     (let (requests callbacks (cancelled 0))
       (setq-local crosslang-provider
                   (list :operations '(express explain translate)
                         :start (lambda (request done)
                                  (push request requests) (push done callbacks)
                                  (lambda () (setq cancelled (1+ cancelled))))))
       (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                 ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
         (unwind-protect (progn ,@body)
           (when crosslang-live-mode (crosslang-live-mode -1))
           (crosslang-mode -1) (gptel-mode -1))))))

(defun crosslang-live-test--fire ()
  ;; Unit tests deterministically dispatch the scheduled callback. Native idle
  ;; delivery is covered separately in the actual running Emacs.
  (when (timerp crosslang-live--timer) (cancel-timer crosslang-live--timer))
  (crosslang-live--fire (current-buffer) crosslang-live--epoch (buffer-chars-modified-tick)))

(defun crosslang-live-test--answer (request)
  (let ((text (plist-get request :text)) edits)
    (dolist (span (reverse (copy-sequence (plist-get request :spans))))
      (let ((start (plist-get span :start)) (end (plist-get span :end)))
        (push (list :start start :end end :text "please check") edits)
        (setq text (concat (substring text 0 start) "please check" (substring text end)))))
    (list :text text :edits edits)))

(ert-deftest crosslang-live-default-off-and-explicit-toggle ()
  (crosslang-live-test--with
    (should-not crosslang-live-mode)
    (should (eq (lookup-key crosslang-short-map (kbd "SPC")) 'crosslang-live-mode))
    (should-not (memq #'crosslang-live--before-change before-change-functions))
    (crosslang-live-mode 1)
    (should (timerp crosslang-live--timer))
    (should-not requests)
    (crosslang-live-test--fire)
    (should (= 1 (length requests)))
    (should (equal "请检查" (plist-get (car requests) :text)))
    (should (eq (plist-get (car requests) :operation) 'express))))

(ert-deftest crosslang-live-delay-independent-of-old-idle-time ()
  (crosslang-live-test--with
    (crosslang-live-mode 1) (crosslang-live--cancel-timer)
    (let (delays)
      (cl-letf (((symbol-function 'current-idle-time) (lambda () (seconds-to-time 20)))
                ((symbol-function 'run-at-time) (lambda (seconds &rest _) (push seconds delays) nil)))
        (crosslang-live--queue) (should (= (car delays) crosslang-live-delay))))
    (let (delay)
      (cl-letf (((symbol-function 'current-idle-time) (lambda () nil))
                ((symbol-function 'run-at-time) (lambda (seconds &rest _) (setq delay seconds) nil)))
        (crosslang-live--post-command) (should (= delay crosslang-live-delay))))))

(ert-deftest crosslang-live-debounce-and-stale-callback ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (let ((epoch crosslang-live--epoch) (tick (buffer-chars-modified-tick)))
      (insert "一下")
      (crosslang-live--fire (current-buffer) epoch tick)
      (should-not requests))
    (crosslang-live-test--fire)
    (let ((old-request (car requests)) (old-done (car callbacks)))
      (insert "现在")
      (should (= 1 cancelled))
      (crosslang-live-test--fire)
      (should (= 2 (length requests)))
      (funcall old-done (crosslang-live-test--answer old-request))
      (should-not crosslang--proposal)
      (funcall (car callbacks) (crosslang-live-test--answer (car requests)))
      (should crosslang--proposal)
      (should (equal "请检查一下现在" (plist-get crosslang--proposal :text))))))

(ert-deftest crosslang-live-never-retries-same-failed-revision ()
  (crosslang-live-test--with
    (crosslang-live-mode 1) (crosslang-live-test--fire)
    (funcall (car callbacks) '(:error "model unavailable"))
    (crosslang-live--queue) (crosslang-live-test--fire)
    (should (= 1 (length requests)))
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-live-dismiss-pending-and-result-until-next-edit ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (crosslang-dismiss)
    (crosslang-live--queue) (crosslang-live-test--fire)
    (should-not requests)
    (insert "文本") (crosslang-live-test--fire)
    (funcall (car callbacks) (crosslang-live-test--answer (car requests)))
    (crosslang-dismiss)
    (crosslang-live--queue) (crosslang-live-test--fire)
    (should (= 1 (length requests)))
    (should-not crosslang--overlays)))

(ert-deftest crosslang-live-manual-reading-has-priority ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (crosslang--request 'explain (cons (1- (point-max)) (point-max)))
    (crosslang-live-test--fire)
    (should (= 1 (length requests)))
    (should (eq (plist-get (car requests) :operation) 'explain))
    (crosslang-live-mode -1)
    (should (= 0 cancelled))
    (should crosslang--timer)))

(ert-deftest crosslang-live-off-cancels-only-owned-and-parent-off-removes-hooks ()
  (crosslang-live-test--with
    (crosslang-live-mode 1) (crosslang-live-test--fire)
    (crosslang-mode -1)
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)
    (should-not crosslang--timer)
    (should (= 1 cancelled))
    (dolist (hook '(before-change-functions after-change-functions post-command-hook
                    gptel-post-response-functions crosslang-before-request-hook
                    crosslang-dismiss-hook crosslang-after-accept-hook))
      (should-not (cl-some (lambda (f) (string-prefix-p "crosslang-live--" (format "%s" f))) (symbol-value hook))))))

(ert-deftest crosslang-live-quail-preedit-and-queued-input-gate ()
  ;; Exercise the real gate rather than the fixture's default composition stub.
  (let ((check (symbol-function 'crosslang-live--composing-p)))
    (cl-progv '(quail-current-key quail-converting unread-command-events) '("ni" nil nil)
      (should (funcall check)))
    (cl-progv '(quail-current-key quail-converting unread-command-events) '("" t nil)
      (should (funcall check)))
    (let ((unread-command-events '(97))) (should (funcall check)))))

(ert-deftest crosslang-live-focused-committed-draft-only ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () nil)))
      (crosslang-live-test--fire) (should-not requests))
    (cl-letf (((symbol-function 'crosslang-live--composing-p) (lambda () t)))
      (crosslang-live--queue) (crosslang-live-test--fire) (should-not requests))
    (crosslang-live--queue) (crosslang-live-test--fire)
    (should (= 1 (length requests)))))

(ert-deftest crosslang-live-busy-review-read-only-and-partial-pause ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (cl-letf (((symbol-function 'crosslang-gptel--bounds) (lambda () (user-error "responding"))))
      (crosslang-live-test--fire) (should-not requests))
    (let ((crosslang--review '(:kind "理解"))) (crosslang-live--queue) (crosslang-live-test--fire) (should-not requests))
    (let ((buffer-read-only t)) (crosslang-live--queue) (crosslang-live-test--fire) (should-not requests))
    (let ((crosslang-assistance 'partial)) (crosslang-live--queue) (crosslang-live-test--fire) (should-not requests))))

(ert-deftest crosslang-live-large-pauses-but-english-generates-chinese ()
  (crosslang-live-test--with
    (crosslang-live-mode 1)
    (let ((crosslang-live-max-characters 1)) (crosslang-live-test--fire) (should-not requests))
    (delete-region (+ (point-min) (length (gptel-prompt-prefix-string))) (point-max))
    (insert "All English") (crosslang-live-test--fire)
    (should (= 1 (length requests)))
    (should (equal (plist-get (car requests) :target) "zh"))
    (should-not (plist-get (car requests) :spans))))

(ert-deftest crosslang-live-keeps-source-undo-and-selection-untouched ()
  (crosslang-live-test--with
    (buffer-enable-undo)
    (let ((source (buffer-string)) (undo buffer-undo-list) (position (point)) (mark (mark t)))
      (crosslang-live-mode 1) (crosslang-live-test--fire)
      (funcall (car callbacks) (crosslang-live-test--answer (car requests)))
      (should (equal source (buffer-string))) (should (equal undo buffer-undo-list))
      (should (= position (point))) (should (equal mark (mark t)))
      (should crosslang--overlays) (should-not crosslang--preview)
      (crosslang-live-mode -1) (should-not crosslang--overlays))))

(ert-deftest crosslang-live-accept-does-not-auto-regenerate ()
  (crosslang-live-test--with
    (buffer-enable-undo)
    (crosslang-live-mode 1) (crosslang-live-test--fire)
    (funcall (car callbacks) (crosslang-live-test--answer (car requests)))
    (cl-letf (((symbol-function 'yes-or-no-p) (lambda (&rest _) t))) (crosslang-accept))
    (should-not crosslang-live--timer)
    (should-not crosslang-live--dirty)
    (crosslang-live--queue) (should-not crosslang-live--timer)
    (should (= 1 (length requests)))))

(ert-deftest crosslang-live-ordinary-buffer-can-enable ()
  (with-temp-buffer
    (text-mode)
    (crosslang-live-mode 1)
    (unwind-protect
        (progn (should crosslang-live-mode) (should crosslang-mode))
      (crosslang-mode -1))
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-live-major-mode-change-stops-owned-process ()
  (crosslang-live-test--with
    (crosslang-live-mode 1) (crosslang-live-test--fire)
    (fundamental-mode)
    (should (= cancelled 1))
    (should-not crosslang-live-mode)
    (should-not crosslang-live--timer)))

(ert-deftest crosslang-live-killed-buffer-cancels-and-ignores-late-results ()
  (let ((buffer (generate-new-buffer " live-test-dead")) callback request)
    (unwind-protect
        (with-current-buffer buffer
          (org-mode) (gptel-mode 1) (insert (gptel-prompt-prefix-string) "你好")
          (crosslang-mode 1)
          (setq-local crosslang-provider (list :operations '(express) :start (lambda (r done) (setq request r callback done) nil)))
          (cl-letf (((symbol-function 'crosslang-live--focused-p) (lambda () t))
                    ((symbol-function 'crosslang-live--composing-p) (lambda () nil)))
            (crosslang-live-mode 1) (crosslang-live-test--fire))
          (gptel-mode -1) (kill-buffer buffer)
          (should-not (buffer-live-p buffer))
          (funcall callback (crosslang-live-test--answer request)))
      (when (buffer-live-p buffer) (kill-buffer buffer)))))
