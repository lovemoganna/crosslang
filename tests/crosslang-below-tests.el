;;; crosslang-below-tests.el --- Virtual newline preview -*- lexical-binding: t; -*-
(require 'ert)
(require 'crosslang-live)

(defmacro crosslang-below-test--with (&rest body)
  `(with-temp-buffer
     (fundamental-mode) (buffer-enable-undo)
     (insert "  请核对日期。\nFollowing line.") (goto-char 5)
     (crosslang-mode 1)
     (unwind-protect (progn ,@body) (crosslang-mode -1))))

(defun crosslang-below-test--show (&optional response)
  (crosslang--show
   (list :operation 'express :text (buffer-substring-no-properties 1 9)
         :start 1 :end 9 :layout 'below :tick (buffer-chars-modified-tick))
   (or response '(:text "Please check the date."))))

(ert-deftest crosslang-below-is-virtual-indented-and-nonediting ()
  (crosslang-below-test--with
    (let ((text (buffer-string)) (undo buffer-undo-list) (position (point))
          (tick (buffer-chars-modified-tick)) (windows (current-window-configuration)))
      (crosslang-below-test--show)
      (should (= 1 (length crosslang--overlays)))
      (let ((overlay (car crosslang--overlays)))
        (should (= (overlay-start overlay) (save-excursion (end-of-line) (point))))
        (should (equal (substring-no-properties (overlay-get overlay 'after-string))
                       "\n  Please check the date.")))
      (should (equal text (buffer-string))) (should (equal undo buffer-undo-list))
      (should (= position (point))) (should (= tick (buffer-chars-modified-tick)))
      (should (compare-window-configurations windows (current-window-configuration)))
      (crosslang-dismiss) (should-not crosslang--overlays))))

(ert-deftest crosslang-below-complete-mixed-result-once-not-per-patch ()
  (crosslang-below-test--with
    (erase-buffer) (insert "Please check 日期 and 预算.")
    (crosslang--show (list :operation 'express :text (buffer-string) :start 1 :end (point-max) :layout 'below)
                     '(:text "Please check date and budget."
                       :edits ((:start 13 :end 15 :text "date") (:start 20 :end 22 :text "budget"))))
    (should (= 1 (length crosslang--overlays)))
    (should (= 2 crosslang--ui-count))
    (should (equal (substring-no-properties (overlay-get (car crosslang--overlays) 'after-string))
                   "\nPlease check date and budget."))))

(ert-deftest crosslang-below-preserves-response-lines-and-tab-alignment ()
  (crosslang-below-test--with
    (erase-buffer) (insert "\tHello") (setq-local tab-width 4)
    (crosslang--show (list :operation 'express :text (buffer-string) :start 1 :end (point-max) :layout 'below)
                     '(:text "你好\n请继续。"))
    (should (equal (substring-no-properties (overlay-get (car crosslang--overlays) 'after-string))
                   "\n    你好\n    请继续。"))))

(ert-deftest crosslang-below-does-not-split-source-or-following-line ()
  (crosslang-below-test--with
    (crosslang--show (list :operation 'express :text "核对" :start 4 :end 6 :layout 'below) '(:text "check"))
    (should (= (overlay-start (car crosslang--overlays)) (save-excursion (end-of-line) (point))))
    (erase-buffer) (insert "Hello\nNEXT")
    (crosslang--show '(:operation express :text "Hello\n" :start 1 :end 7 :layout below) '(:text "你好"))
    (should (equal (substring-no-properties (overlay-get (car crosslang--overlays) 'after-string)) "你好\n"))))

(ert-deftest crosslang-below-errors-stay-blocked-and-mode-off-removes-lines ()
  (crosslang-below-test--with
    (crosslang-below-test--show '(:text "Which date?" :uncertain t))
    (should (eq crosslang--ui-status 'uncertain))
    (should (string-match-p "\n  \\[需澄清\\]" (overlay-get (car crosslang--overlays) 'after-string)))
    (should-error (crosslang-accept) :type 'user-error)
    (let ((overlay (car crosslang--overlays)))
      (crosslang-mode -1)
      (should-not (overlay-buffer overlay)))))

(ert-deftest crosslang-below-layout-only-for-automatic-request ()
  (crosslang-below-test--with
    (setq-local crosslang-provider (list :operations '(express) :start (lambda (_request done)
                                   (funcall done '(:text "请核对日期。")) nil)))
    (let ((crosslang-live--dispatching t)) (crosslang--request 'express '(1 . 9) nil "zh"))
    (should (eq (plist-get crosslang--proposal :layout) 'below))
    (crosslang-dismiss)
    (crosslang--request 'express '(1 . 9) nil "zh")
    (should-not (plist-get crosslang--proposal :layout))))
