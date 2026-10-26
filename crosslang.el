;;; crosslang.el --- On-demand communication assistance -*- lexical-binding: t; -*-
;; Version: 0.1.0
;; URL: https://github.com/lovemoganna/crosslang
;; Package-Requires: ((emacs "29.1"))
;; No global hooks, network calls, or automatic text changes at load time.
(require 'cl-lib)
(require 'subr-x)

(defgroup crosslang nil "Assistance inside an existing conversation." :group 'applications)
(require 'crosslang-ui)
(require 'crosslang-style)
(defcustom crosslang-assistance 'on-demand "User-selected assistance scope.
All scopes require an explicit request; none sends messages."
  :type '(choice (const full) (const partial) (const on-demand)))
(defcustom crosslang-target-language "en" "Expression target." :type 'string)
(defcustom crosslang-reading-language "zh" "Explanation target." :type 'string)
(defcustom crosslang-timeout 30 "Maximum seconds per request." :type 'number)
(defcustom crosslang-presentation 'inline "Default result presentation. Details are always available on demand."
  :type '(choice (const inline) (const buffer)))
(defcustom crosslang-context-enabled t "Use bounded local conversation context in an enabled chat." :type 'boolean)
(defvar-local crosslang--overlays nil)
(defvar-local crosslang--watched nil)
(defvar-local crosslang--review nil)
(defvar-local crosslang-review-results nil)
(defcustom crosslang-provider nil "Async provider plist: :name, :operations, :start.
START receives a request plist and callback, and returns a cancellation function.
Requests contain :operation, :text, :target, :assistance.  No transcript is
implicitly included.  Callback receives :text, optional :uncertain, or :error."
  :type 'sexp)
(defvar crosslang-adapters nil "List of (PREDICATE . DRAFT-BOUNDS-FUNCTION).
Bounds functions return editable draft bounds; they must never create sessions.")
(defvar-local crosslang--cancel nil)
(defvar-local crosslang--timer nil)
(defvar-local crosslang--generation 0)
(defvar-local crosslang--proposal nil)
(defvar-local crosslang--preview nil)
(defvar-local crosslang--origin nil)
(defvar-local crosslang--ui-status nil)
(defvar-local crosslang--ui-count 0)
(defvar crosslang-before-request-hook nil "Run before a manual or automatic assistance request.")
(defvar crosslang-dismiss-hook nil "Run in the source buffer after explicit dismissal.")
(defvar crosslang-after-accept-hook nil "Run after a confirmed candidate is applied.")
(defvar crosslang-result-hook nil "Run after a current result has been displayed.")
(defvar crosslang--automatic-writer nil
  "Dynamically scoped, explicitly enabled writer with :authorize and :write functions.
Nil means every write requires the usual interactive confirmation.")
(defvar crosslang-error-functions nil
  "Functions called with an error response; may return a user-facing notice.")

(defun crosslang--format-error (response)
  "Describe resource failures with a recovery step instead of an exception name."
  (concat
   (pcase (plist-get response :error_code)
     ("model-not-loaded" "Bionic 尚未加载文本模型，请先加载一个本地文本模型")
     ("selected-model-not-loaded" "指定模型尚未加载，请在 Bionic 加载它，或检查 crosslang-local-model")
     ("model-selection-required" "Bionic 已加载多个模型，请通过 crosslang-local-model 明确选择")
     ("service-unavailable" "无法连接本地语言服务，请检查 Bionic 服务和 crosslang-local-port")
     (_ (concat "语言辅助失败：" (or (plist-get response :error) "未知错误"))))
   "；原文保留，离线词典仍可使用"))

(defun crosslang--adapter ()
  "Return the active conversation adapter, if any."
  (cl-find-if (lambda (entry) (funcall (car entry))) crosslang-adapters))

(defun crosslang--plain-editor-p ()
  "Allow editable buffers of any major mode without bypassing a chat adapter."
  (and (not (bound-and-true-p gptel-mode))
       (not buffer-read-only) (not (minibufferp))))

(defun crosslang--editable-line-bounds ()
  "Return only the current writable line, excluding a process's output/prompt.
No major-mode whitelist; raw terminal input and read-only text are not edited."
  (unless (crosslang--plain-editor-p) (user-error "当前缓冲区不可编辑"))
  (let ((start (line-beginning-position)) (end (line-end-position))
        (process (get-buffer-process (current-buffer))))
    (when (and process (marker-position (process-mark process)))
      (setq start (max start (marker-position (process-mark process)))))
    ;; Eshell and other modes may expose a read-only prompt without a process.
    (while (and (< start end) (get-text-property start 'read-only))
      (setq start (next-single-property-change start 'read-only nil end)))
    (unless (and (< start end) (<= start (point))
                 (not (text-property-not-all start end 'read-only nil)))
      (user-error "当前行没有可编辑的输入内容"))
    (cons start end)))

(defun crosslang--bounds ()
  "Get writable bounds, keeping conversation transcripts under their adapter."
  (if-let* ((adapter (crosslang--adapter)))
      (funcall (cdr adapter))
    (if (crosslang--plain-editor-p) (cons (point-min) (point-max))
      (user-error "Use a supported conversation or select text in an ordinary editable buffer"))))

(defun crosslang--selected-bounds ()
  (unless (use-region-p) (user-error "Select the text to explain or translate"))
  (cons (region-beginning) (region-end)))

(defun crosslang--cancel-request ()
  "Invalidate callbacks before cancelling asynchronous work."
  (cl-incf crosslang--generation)
  (when (timerp crosslang--timer) (cancel-timer crosslang--timer))
  (setq crosslang--timer nil crosslang--ui-status nil)
  (force-mode-line-update)
  (remove-hook 'before-change-functions #'crosslang--changed t)
  (when crosslang--watched
    (set-marker (nth 1 crosslang--watched) nil)
    (set-marker (nth 2 crosslang--watched) nil)
    (setq crosslang--watched nil))
  (let ((cancel crosslang--cancel))
    (setq crosslang--cancel nil)
    (when cancel (condition-case nil (funcall cancel) (error nil)))))

(defun crosslang--dispose-preview ()
  ;; quit-window can switch the current buffer. Capture the exact object and
  ;; clear the origin's locals before touching windows or running kill hooks.
  (let ((preview crosslang--preview))
    (mapc #'delete-overlay crosslang--overlays)
    (setq crosslang--overlays nil)
    (setq crosslang--preview nil crosslang--proposal nil crosslang--ui-status nil crosslang--ui-count 0)
    (force-mode-line-update)
    (when (buffer-live-p preview)
      (save-current-buffer
        (dolist (window (get-buffer-window-list preview nil t))
          (quit-window nil window))
        (kill-buffer preview)))))

(defun crosslang--cleanup ()
  (crosslang--cancel-request)
  (crosslang--dispose-preview))

(defun crosslang--changed (beg end)
  "Revoke only pending assistance when the source changes; never scan text."
  (when (or (not crosslang--watched)
            (eq (car crosslang--watched) 'express)
            (and (<= beg (marker-position (nth 2 crosslang--watched)))
                 (>= end (marker-position (nth 1 crosslang--watched)))))
    (crosslang--cleanup)))

(defun crosslang--spans (text explicit)
  "Return editable Chinese islands, or the explicitly selected non-Chinese text."
  (let ((pos 0) (id 0) spans)
    (while (string-match "[㐀-鿿]+\\(?:[，。？！；：、 \t]*[㐀-鿿]+\\)*[，。？！；：、]?" text pos)
      (push (list :id id :start (match-beginning 0) :end (match-end 0)
                  :text (match-string 0 text)) spans)
      (setq pos (match-end 0) id (1+ id)))
    (or (nreverse spans)
        (when explicit (list (list :id 0 :start 0 :end (length text) :text text))))))

(defun crosslang--context (bounds)
  (when crosslang-context-enabled
    (when-let* ((adapter (crosslang--adapter))
                (_ (symbolp (cdr adapter)))
                (function (get (cdr adapter) 'crosslang-context-function)))
      (funcall function bounds))))

(defun crosslang--numbers (text)
  (let ((start 0) found)
    (while (string-match "[0-9]+\\(?:[.,][0-9]+\\)*" text start)
      (push (match-string 0 text) found)
      (setq start (match-end 0)))
    (sort found #'string<)))

(defun crosslang--reading-context (bounds)
  "Return the selected passage's own sentence, capped at 1500 characters."
  (when crosslang-context-enabled
    (save-excursion
      (goto-char (car bounds))
      (let* ((start (progn (skip-chars-backward "^.!?。！？\n") (point)))
             (end (progn (goto-char (cdr bounds)) (skip-chars-forward "^.!?。！？\n") (point)))
             (left (max start (- (car bounds) 700))))
        (buffer-substring-no-properties left (min end (+ (cdr bounds) 700) (+ left 1500)))))))

(defun crosslang--chinese-number (text)
  "Convert ordinary nonnegative Chinese integer TEXT, or return nil."
  (let ((digits '((?零 . 0) (?〇 . 0) (?一 . 1) (?二 . 2) (?两 . 2)
                  (?三 . 3) (?四 . 4) (?五 . 5) (?六 . 6) (?七 . 7) (?八 . 8) (?九 . 9)))
        (units '((?十 . 10) (?百 . 100) (?千 . 1000)))
        (total 0) (section 0) (number 0))
    (dolist (char (string-to-list text))
      (cond ((assq char digits) (setq number (cdr (assq char digits))))
            ((assq char units)
             (setq section (+ section (* (max number 1) (cdr (assq char units)))) number 0))
            ((eq char ?万) (setq total (+ total (* (+ section number) 10000)) section 0 number 0))))
    (if (string-match-p "[十百千万]" text) (+ total section number)
      (string-to-number (mapconcat (lambda (c) (number-to-string (cdr (assq c digits)))) (string-to-list text) "")))))

(defun crosslang--ordered-amounts (text)
  "Compare numeric anchors in order, including Chinese quantities with units.
This is a conservative guard, not a semantic equivalence proof."
  (let ((pos 0) values)
    (while (string-match
            "[-+]?[0-9]+\\(?:[.,][0-9]+\\)*\\|[零〇一二两三四五六七八九十百千万]+[ \t]*\\(?:美元\\|元\\|英镑\\|欧元\\|日元\\|天\\|小时\\|分钟\\|件\\|个\\|%\\)" text pos)
      (let ((token (match-string 0 text)) (next (match-end 0)))
        (push (if (string-match "\\`\\([零〇一二两三四五六七八九十百千万]+\\)" token)
                  (number-to-string (crosslang--chinese-number (match-string 1 token)))
                (replace-regexp-in-string "," "" token)) values)
        (setq pos next)))
    (nreverse values)))

(defun crosslang--semantic-issues (source candidate)
  "Return concrete, conservative reasons to reject automatic writeback."
  (let ((case-fold-search t) issues)
    (when (string-match-p "[壹贰叁肆伍陆柒捌玖拾佰仟亿]\\|[零〇一二两三四五六七八九十百千万]+点\\|负[零〇一二两三四五六七八九十百千万]" source)
      (push "本次中文数量写法无法可靠核验，请明确写成阿拉伯数字后重试" issues))
    (unless (= (cl-count ?% source) (cl-count ?% candidate))
      (push "百分号被新增或省略" issues))
    (unless (equal (crosslang--ordered-amounts source) (crosslang--ordered-amounts candidate))
      (push "数字、数量或其出现顺序发生变化" issues))
    (unless (equal (crosslang--currency-sequence source) (crosslang--currency-sequence candidate))
      (push "币种或其出现顺序发生变化" issues))
    (dolist (rule '(("至少\\|不少于\\|不低于\\|\\bat least\\b\\|\\bminimum\\b" . "下限")
                    ("最多\\|不超过\\|不要超过\\|不得超过\\|至多\\|\\bat most\\b\\|\\bno more than\\b\\|\\bmaximum\\b\\|\\bnot exceed\\b\\|\\bnever exceed\\b" . "上限")
                    ("除非\\|\\bunless\\b" . "例外条件")
                    ("如果\\|若\\|\\bif\\b\\|\\bprovided that\\b" . "前提条件")))
      (unless (eq (not (string-match-p (car rule) source)) (not (string-match-p (car rule) candidate)))
        (push (concat (cdr rule) "表达缺失或被新增") issues)))
    (let ((source (replace-regexp-in-string
                   "不要超过\\|不得超过\\|不超过\\|不少于\\|不低于\\|\\bnot exceed\\b\\|\\bno more than\\b\\|\\bnever exceed\\b" "" source)))
     (when (and (string-match-p "禁止\\|不得\\|不要\\|不能\\|\\bnot\\b\\|\\bnever\\b\\|\\bmustn't\\b\\|\\bdon't\\b" source)
               (not (string-match-p "不\\|禁止\\|\\bnot\\b\\|\\bnever\\b\\|\\bno\\b\\|\\bmustn't\\b\\|\\bdon't\\b" candidate)))
      (push "原文的否定或禁止可能被省略" issues)))
    (nreverse issues)))

(defun crosslang--currency-sequence (text)
  "Normalize explicit currency names in order without guessing bare symbols."
  (let ((case-fold-search t) (pos 0) found)
    (while (string-match "美元\\|人民币\\|欧元\\|英镑\\|日元\\|USD\\|CNY\\|RMB\\|EUR\\|GBP\\|JPY" text pos)
      (let ((token (upcase (match-string 0 text))) (start (match-beginning 0)) (end (match-end 0)))
       (unless (and (string-match-p "\\`[A-Z]+\\'" token)
                    (or (and (> start 0) (string-match-p "[A-Za-z]" (substring text (1- start) start)))
                        (and (< end (length text)) (string-match-p "[A-Za-z]" (substring text end (1+ end))))))
        (push (or (cdr (assoc token '(("美元" . "USD") ("人民币" . "CNY")
                                     ("RMB" . "CNY") ("欧元" . "EUR") ("英镑" . "GBP") ("日元" . "JPY")))) token) found))
       (setq pos end)))
    (nreverse found)))

(defun crosslang--review-flags (source candidate)
  "Conservative hints, never a claim of semantic equivalence."
  (delq nil
        (list (unless (equal (crosslang--numbers source) (crosslang--numbers candidate))
                "数字出现变化：请核对金额、日期与数量限制。")
              (when (string-match-p
                     "不\\|没\\|禁止\\|仅\\|最多\\|至少\\|不得\\|\\b\\(?:not\\|never\\|only\\|must\\|unless\\|at most\\)\\b"
                     (downcase source))
                "原文含否定或限制：请核对义务、条件与上下限。")
              "候选未经语义认证，请核对对象、名称、币种与条件。")))

(defvar crosslang-preview-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "a") #'crosslang-accept)
    (define-key map (kbd "b") #'crosslang-insert-bilingual)
    (define-key map (kbd "q") #'crosslang-dismiss)
    map))

(defun crosslang--preview-killed ()
  "Revoke the result when its own preview is closed manually."
  (let ((preview (current-buffer)) (origin crosslang--origin))
    (when (buffer-live-p origin)
      (with-current-buffer origin
        (when (eq crosslang--preview preview)
          (setq crosslang--preview nil crosslang--proposal nil)
          (crosslang--cleanup))))))

(define-derived-mode crosslang-preview-mode special-mode "Language candidate"
  "Read-only candidate; a accepts after confirmation; q dismisses."
  (when (fboundp 'evil-make-overriding-map)
    (evil-make-overriding-map crosslang-preview-mode-map 'normal)
    (evil-normalize-keymaps))
  (add-hook 'kill-buffer-hook #'crosslang--preview-killed nil t))

(defun crosslang--show-buffer (proposal response)
  (let ((origin (current-buffer)))
    (setq crosslang--preview (generate-new-buffer "*Language candidate*"))
    (with-current-buffer crosslang--preview
      (crosslang-ui-insert-details proposal response
        (when (eq (plist-get proposal :operation) 'express)
          (crosslang--semantic-issues (plist-get proposal :text) (or (plist-get response :text) "")))
        (crosslang--review-flags (plist-get proposal :text) (or (plist-get response :text) "")))
      (crosslang-preview-mode)
      (setq-local crosslang--origin origin
                  header-line-format (if (eq (plist-get proposal :operation) 'express)
                                         " a 确认替换 · b 中英分行写入 · q 关闭" " q 关闭")
                  truncate-lines nil word-wrap t))
    ;; Standard display-buffer policy remains under user control; no focus theft.
    (display-buffer crosslang--preview)))

(defun crosslang-show-details ()
  "Expand the current result only on explicit request."
  (interactive)
  (let ((origin (or crosslang--origin (current-buffer))))
    (unless (buffer-live-p origin) (user-error "Original buffer is closed"))
    (with-current-buffer origin
      (unless crosslang--proposal (user-error "No current language result"))
      (if (buffer-live-p crosslang--preview) (display-buffer crosslang--preview)
        (crosslang--show-buffer crosslang--proposal (plist-get crosslang--proposal :response))))))

(defun crosslang--show (proposal response)
  "Present in the source buffer without changing its text, undo or focus."
  (crosslang--dispose-preview)
  (setq crosslang--proposal (append proposal (list :response response)))
  (let ((issues (when (eq (plist-get proposal :operation) 'express)
                  (crosslang--semantic-issues (plist-get proposal :text) (or (plist-get response :text) "")))))
   (setq crosslang--ui-status (cond ((plist-get response :uncertain) 'uncertain) (issues 'blocked)
                                  ((eq (plist-get proposal :operation) 'express) 'ready) (t 'reading)))
   (if (eq crosslang-presentation 'buffer)
      (crosslang--show-buffer proposal response)
    (let ((view (crosslang-ui-render proposal response issues)))
      (setq crosslang--overlays (plist-get view :overlays)
            crosslang--ui-status (plist-get view :state)
            crosslang--ui-count (plist-get view :count)))))
  (force-mode-line-update)
  (run-hooks 'crosslang-result-hook))

(defun crosslang--request (operation bounds &optional explicit target)
  (unless crosslang-mode (user-error "Enable crosslang-mode first"))
  (when crosslang--review (user-error "无提示回顾进行中；先用 C-c L R 记录结果或关闭 Mode"))
  (unless (memq operation (plist-get crosslang-provider :operations))
    (user-error "No installed provider supports %s; original text retained" operation))
  (run-hooks 'crosslang-before-request-hook)
  (let* ((target (or target (if (eq operation 'express) crosslang-target-language
                             crosslang-reading-language)))
         (text (buffer-substring-no-properties (car bounds) (cdr bounds)))
         (proposal (list :operation operation :text text :start (car bounds)
                         :end (cdr bounds) :target target
                         :layout (when (bound-and-true-p crosslang-live--dispatching) 'below)
                         :tick (buffer-chars-modified-tick)))
         (spans (when (and (eq operation 'express) (equal target "en")
                           (not (eq crosslang-assistance 'full)))
                  (crosslang--spans text explicit)))
         (request (list :operation operation :text text
                        :context (if (eq operation 'express) (crosslang--context bounds)
                                   (crosslang--reading-context bounds)) :spans spans
                        :target target
                        :assistance crosslang-assistance))
         (origin (current-buffer)))
    (when (string-empty-p (string-trim text)) (user-error "No text selected"))
    (when (and (eq operation 'express) (equal target "en")
               (not (eq crosslang-assistance 'full)) (not spans))
      (user-error "已有英文保持不变；选中需要帮助的词句，或切换 full 辅助"))
    (crosslang--cancel-request)
    (crosslang--dispose-preview)
    (setq crosslang--watched (list operation (copy-marker (car bounds)) (copy-marker (cdr bounds) t)))
    (setq proposal (plist-put proposal :anchor (nth 2 crosslang--watched)))
    (add-hook 'before-change-functions #'crosslang--changed nil t)
    (setq crosslang--ui-status 'working)
    (force-mode-line-update)
    (let ((generation crosslang--generation) (finished nil))
      (cl-labels ((done (response)
                    (when (and (not finished) (buffer-live-p origin))
                      (with-current-buffer origin
                        (when (and crosslang-mode (= generation crosslang--generation))
                          (setq finished t crosslang--cancel nil)
                          (when (timerp crosslang--timer) (cancel-timer crosslang--timer))
                          (setq crosslang--timer nil)
                          (if-let* ((error-text (plist-get response :error)))
                              (let ((notice (run-hook-with-args-until-success 'crosslang-error-functions response)))
                                (crosslang--cleanup)
                                (setq crosslang--ui-status 'failed)
                                (force-mode-line-update)
                                (message "%s" (or notice (crosslang--format-error response))))
                            (if (and (eq operation 'express) spans
                                     (not (plist-get response :uncertain))
                                     (not (crosslang--valid-edits-p text spans response)))
                                (progn (crosslang--cleanup)
                                       (message "候选未遵守局部修改边界，已拒绝；原文保留"))
                              (crosslang--show proposal response))))))))
        (setq crosslang--timer
              (run-at-time crosslang-timeout nil
                           (lambda ()
                             (when (buffer-live-p origin)
                               (with-current-buffer origin
                                 (when (= generation crosslang--generation)
                                   (crosslang--cancel-request)
                                   (setq crosslang--ui-status 'failed)
                                   (force-mode-line-update)
                                   (message "Language request timed out; original retained")))))))
        (condition-case err
            (let ((cancel (funcall (plist-get crosslang-provider :start) request #'done)))
              (unless finished (setq crosslang--cancel cancel)))
          (error (done (list :error (error-message-string err)))))))))

(defun crosslang-express ()
  "Request a candidate for the editable draft, or just its selected obstacle."
  (interactive)
  (unless crosslang-mode (user-error "Enable crosslang-mode first"))
  (let* ((explicit (use-region-p))
         (selection-only (not (crosslang--adapter)))
         (draft (crosslang--bounds))
         (bounds (if selection-only
                     (crosslang--selected-bounds)
                   (if (eq crosslang-assistance 'full) draft
                     (if (use-region-p) (crosslang--selected-bounds) draft)))))
    (unless (and (<= (car draft) (car bounds)) (<= (cdr bounds) (cdr draft)))
      (user-error "Expression requests must stay within the unsent draft"))
    (when (and (eq crosslang-assistance 'partial) (not explicit))
      (user-error "Partial assistance: select only the words you want help with"))
    (crosslang--request 'express bounds explicit)))

(defun crosslang--valid-edits-p (text spans response)
  "Validate backend edits and reconstruct the result without trusting offsets."
  (condition-case nil
   (let ((edits (plist-get response :edits)) (result text) seen valid)
    (setq valid (= (length edits) (length spans)))
    (dolist (edit (sort (copy-sequence edits) (lambda (a b) (> (or (plist-get a :start) -1) (or (plist-get b :start) -1)))))
      (let* ((start (plist-get edit :start)) (end (plist-get edit :end))
             (replacement (plist-get edit :text))
             (span (cl-find-if (lambda (s) (and (equal start (plist-get s :start)) (equal end (plist-get s :end)))) spans)))
        (if (or (not span) (member start seen) (not (stringp replacement))) (setq valid nil)
          (push start seen)
          (setq result (concat (substring result 0 start) replacement (substring result end))))))
    (and valid (equal result (plist-get response :text))))
   (error nil)))

(defun crosslang--reading-bounds (thing)
  (or (when (use-region-p) (crosslang--selected-bounds))
      (bounds-of-thing-at-point thing)
      (user-error "Point at text or select the passage")))

(defun crosslang-explain ()
  "Explain selected incoming text using installed capabilities."
  (interactive) (crosslang--request 'explain (crosslang--reading-bounds 'word)))
(defun crosslang-translate ()
  "Explicitly translate selected incoming text; never replace it."
  (interactive) (crosslang--request 'translate (crosslang--reading-bounds 'paragraph)))

(defun crosslang-accept (&optional bilingual)
  "Confirm a still-current draft in one native undo transaction.
With BILINGUAL non-nil, retain the source and append the complete candidate.
Both paths share all current-draft and semantic guards; neither sends."
  (interactive)
  (let ((origin (or crosslang--origin (current-buffer))))
    (unless (buffer-live-p origin) (user-error "Original conversation is closed"))
    (with-current-buffer origin
      (unless (and crosslang-mode crosslang--proposal) (user-error "No active candidate"))
      (let* ((p crosslang--proposal) (r (plist-get p :response))
             (generation crosslang--generation)
             (start (plist-get p :start)) (end (plist-get p :end))
             (candidate (plist-get r :text)) (draft (crosslang--bounds))
             (automatic (and crosslang--automatic-writer
                             (funcall (plist-get crosslang--automatic-writer :authorize) p))))
        (when (and crosslang--automatic-writer (not automatic))
          (user-error "自动写入范围已改变；原文和已有译文保留"))
        (unless (eq (plist-get p :operation) 'express) (user-error "Reading results cannot replace text"))
        (when (plist-get r :uncertain) (user-error "Clarify the ambiguous intent first"))
        (unless (and (stringp candidate) (not (string-empty-p (string-trim candidate))))
          (user-error "No supported candidate"))
        (unless (or (null (crosslang--numbers (plist-get p :text)))
                    (equal (crosslang--numbers (plist-get p :text)) (crosslang--numbers candidate)))
          (user-error "数值发生变化，拒绝自动写回；请澄清或手动编辑"))
        (when-let* ((issues (crosslang--semantic-issues (plist-get p :text) candidate)))
          (user-error "%s；已阻止写回。请查看原文和候选，澄清后重试或自行编辑"
                      (string-join issues "；")))
        (let ((case-fold-search t))
          (dolist (currency '("USD" "CNY" "RMB" "EUR" "GBP" "JPY"))
            (when (and (string-match-p (concat "\\b" currency "\\b") (plist-get p :text))
                       (not (string-match-p (concat "\\b" currency "\\b") candidate)))
              (user-error "币种 %s 被改变或省略，拒绝自动写回" currency))))
        (unless (and (= (plist-get p :tick) (buffer-chars-modified-tick))
                     (<= (car draft) start) (<= end (cdr draft))
                     (equal (plist-get p :text) (buffer-substring-no-properties start end)))
          (user-error "Conversation or draft changed; request a fresh candidate"))
        (when buffer-read-only (user-error "Draft is read-only"))
        (when (and (not automatic)
                   (> (string-width (replace-regexp-in-string "[\n\r]+" " · " candidate)) 180)
                   (not (buffer-live-p crosslang--preview)))
          (crosslang-show-details)
          (user-error "长候选已展开完整原文和结果；核对后再按 %s 确认"
                      (if bilingual "SPC - b" "SPC - RET")))
        (unless (or automatic (yes-or-no-p
                 (if bilingual
                     "保留原文，按「原文在上、译文在下」写入当前缓冲区？已核对否定、条件、名称和金额？ "
                   "Reviewed negation, constraints, names and amounts? Replace draft only? ")))
          (user-error "Original retained"))
        ;; Incoming output can arrive while the confirmation minibuffer is open.
        (unless (and crosslang-mode (eq p crosslang--proposal)
                     (= generation crosslang--generation)
                     (= (plist-get p :tick) (buffer-chars-modified-tick))
                     (equal draft (crosslang--bounds)))
          (user-error "Candidate cancelled or conversation changed; original retained"))
        (crosslang--cleanup)
        (undo-boundary)
        (crosslang-style-transaction
         (atomic-change-group
          (cond
           (automatic (funcall (plist-get crosslang--automatic-writer :write) candidate))
           (bilingual
              ;; Append, retaining the original text and its native properties.
              (progn (goto-char end) (insert "\n" candidate)
                     (crosslang-style-note-region (1+ end) (point))))
           (t (if-let* ((edits (plist-get r :edits)))
              (dolist (edit (sort (copy-sequence edits) (lambda (a b) (> (plist-get a :start) (plist-get b :start)))))
                (goto-char (+ start (plist-get edit :start)))
                (delete-region (point) (+ start (plist-get edit :end)))
                (insert (plist-get edit :text))
                (crosslang-style-note-region (+ start (plist-get edit :start)) (point)))
              (goto-char start) (delete-region start end) (insert candidate)
              (crosslang-style-note-region start (point)))))))
        (undo-boundary)
        (crosslang--dispose-preview)
        (run-hooks 'crosslang-after-accept-hook)
        (unless automatic (message (if bilingual
                     "中英分行内容已写入当前缓冲区；未保存、未发送，可撤销恢复。"
                   "Candidate applied to draft. Use the Agent's normal send command when ready.")))))))

(defun crosslang-insert-bilingual ()
  "Confirm and append the current translation below its source.
Reuse the existing candidate without a new model request.  Never save or send."
  (interactive)
  (crosslang-accept t))

(defun crosslang-dismiss ()
  "Discard request and result without changing the conversation."
  (interactive)
  (let ((origin (or crosslang--origin (current-buffer))))
    (when (buffer-live-p origin)
      (with-current-buffer origin (crosslang--cleanup) (run-hooks 'crosslang-dismiss-hook)))))

(defun crosslang-set-assistance (level)
  "Explicitly choose LEVEL; never infer proficiency from request counts."
  (interactive (list (intern (completing-read "Assistance: " '("full" "partial" "on-demand") nil t))))
  (unless (memq level '(full partial on-demand)) (user-error "Unknown assistance level"))
  (crosslang--cleanup)
  (setq-local crosslang-assistance level))

(defvar crosslang-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "C-c L e") #'crosslang-express)
    (define-key map (kbd "C-c L d") #'crosslang-explain)
    (define-key map (kbd "C-c L t") #'crosslang-translate)
    (define-key map (kbd "C-c L a") #'crosslang-accept)
    (define-key map (kbd "C-c L b") #'crosslang-insert-bilingual)
    (define-key map (kbd "C-c L q") #'crosslang-dismiss)
    (define-key map (kbd "C-c L s") #'crosslang-set-assistance)
    (define-key map (kbd "C-c L v") #'crosslang-show-details)
    (define-key map (kbd "C-c L x") #'crosslang-toggle-context)
    (define-key map (kbd "C-c L r") #'crosslang-review-start)
    (define-key map (kbd "C-c L R") #'crosslang-review-finish)
    map))

(defun crosslang-dwim ()
  "Express a draft or explain incoming text at point; never send."
  (interactive)
  (unless crosslang-mode (user-error "先用 M-x crosslang-enable 开启语言辅助"))
  (if-let* ((adapter (crosslang--adapter))
            (smart (and (symbolp (cdr adapter)) (get (cdr adapter) 'crosslang-dwim-function))))
      (funcall smart)
   (if (crosslang--adapter)
      (let ((draft (condition-case nil (crosslang--bounds) (user-error nil))))
        (if (and draft (>= (point) (car draft))
                 (or (not (use-region-p)) (>= (region-beginning) (car draft))))
            (crosslang-express)
          (crosslang-explain)))
    (if (and (use-region-p) (string-match-p "[㐀-鿿]"
                           (buffer-substring-no-properties (region-beginning) (region-end))))
        (crosslang-express)
      (crosslang-explain)))))

(defun crosslang-key-help ()
  (interactive)
  (if (fboundp 'hydra-crosslang/body)
      (call-interactively #'hydra-crosslang/body)
    (message "SPC - 后：SPC 动态开关 · - 智能辅助 · e 表达 · d 释义 · t 翻译 · RET 接受 · c 取消 · v 详情 · s 程度 · x 语境")))

(defvar crosslang-short-map
  (let ((map (make-sparse-keymap)))
    (dolist (entry '(("-" . crosslang-dwim) ("e" . crosslang-express)
                     ("d" . crosslang-explain) ("t" . crosslang-translate)
                     ("RET" . crosslang-accept) ("a" . crosslang-accept)
                     ("b" . crosslang-insert-bilingual)
                     ("q" . crosslang-dismiss) ("c" . crosslang-dismiss) ("v" . crosslang-show-details)
                     ("s" . crosslang-set-assistance) ("x" . crosslang-toggle-context)
                     ("r" . crosslang-review-start) ("R" . crosslang-review-finish)
                     ("?" . crosslang-key-help)))
      (define-key map (kbd (car entry)) (cdr entry)))
    map))
;; Buffer-local minor-mode prefix; global and original sending keys stay intact.
(when (eq (lookup-key crosslang-mode-map (kbd "C-=")) crosslang-short-map)
  (define-key crosslang-mode-map (kbd "C-=") nil))
;; defvar preserves the live keymap on reload; migrate its repeated-prefix key.
(when (eq (lookup-key crosslang-short-map (kbd "C-=")) #'crosslang-dwim)
  (define-key crosslang-short-map (kbd "C-=") nil))
(define-key crosslang-short-map (kbd "M--") nil)
(define-key crosslang-short-map (kbd "-") #'crosslang-dwim)
(define-key crosslang-short-map (kbd "c") #'crosslang-dismiss)
(define-key crosslang-short-map (kbd "b") #'crosslang-insert-bilingual)
(define-key crosslang-preview-mode-map (kbd "b") #'crosslang-insert-bilingual)
;; Release only our old binding; preserve any explicit user replacement.
(when (or (eq (lookup-key crosslang-mode-map (kbd "M--")) 'hydra-crosslang/body)
          (eq (lookup-key crosslang-mode-map (kbd "M--")) crosslang-short-map))
  (define-key crosslang-mode-map (kbd "M--") nil))

;; Also initialize newly introduced keys on hot reload, without replacing a
;; user's explicit bindings already present in this package's keymap.
(dolist (entry '(("C-c L v" . crosslang-show-details)
                 ("C-c L b" . crosslang-insert-bilingual)
                 ("C-c L x" . crosslang-toggle-context)
                 ("C-c L r" . crosslang-review-start)
                 ("C-c L R" . crosslang-review-finish)))
  (unless (lookup-key crosslang-mode-map (kbd (car entry)))
    (define-key crosslang-mode-map (kbd (car entry)) (cdr entry))))

;;;###autoload
(define-minor-mode crosslang-mode
  "Buffer-local, on-demand assistance. Never sends; source guards exist only during a request or preview."
  :lighter (:eval (crosslang-ui-lighter crosslang--ui-status crosslang--ui-count)) :keymap crosslang-mode-map
  (if crosslang-mode
      (condition-case err
          (progn
            (unless crosslang-provider
              (require 'crosslang-local)
              (crosslang-local-use))
            (add-hook 'kill-buffer-hook #'crosslang--cleanup nil t))
        (error (setq crosslang-mode nil) (signal (car err) (cdr err))))
    (crosslang--cleanup)
    (setq crosslang--review nil)
    (remove-hook 'kill-buffer-hook #'crosslang--cleanup t)))

;;;###autoload
(defun crosslang-enable ()
  "Enable assistance without creating a conversation or sending text.
Conversations use their adapter; ordinary editors require an explicit selection."
  (interactive)
  (crosslang-mode 1)
  (message (if (fboundp 'hydra-crosslang/body)
               "CrossLang 已开启：SPC - 打开语言辅助菜单；q 退出菜单，c 取消候选"
             (if (crosslang--adapter)
               "CrossLang 已开启：SPC - - 智能辅助；SPC - SPC 动态开关；SPC - ? 查看按键"
               "CrossLang 已开启：选中文本后 SPC - -；SPC - ? 查看按键"))))

(defun crosslang-toggle-context ()
  (interactive)
  (crosslang--cleanup)
  (setq-local crosslang-context-enabled (not crosslang-context-enabled))
  (message "本地会话上下文：%s" (if crosslang-context-enabled "最近一条回复，最多 1500 字符" "关闭")))

(defun crosslang-review-start (kind)
  "Voluntary unassisted review inside the existing workflow; creates no task."
  (interactive (list (completing-read "无提示回顾：" '("表达" "理解" "澄清") nil t)))
  (unless crosslang-mode (user-error "Enable crosslang-mode first"))
  (crosslang--cleanup)
  (setq crosslang--review (list :kind kind :started (float-time)))
  (message "当前缓冲区暂停语言提示；按日常方式表达/复述/澄清，完成后 SPC - R"))

(defun crosslang-review-finish (outcome critical)
  "Record a user-assessed result in memory, never infer proficiency from counts."
  (interactive (progn (unless crosslang--review (user-error "没有进行中的回顾"))
                      (list (completing-read "结果：" '("独立完成" "自行修正后完成" "需要提示") nil t)
                            (yes-or-no-p "是否出现否定、金额或条件等关键语义错误？ "))))
  (unless crosslang--review (user-error "没有进行中的回顾"))
  (push (append crosslang--review (list :outcome outcome :critical-error critical :unassisted t)) crosslang-review-results)
  (setq crosslang--review nil)
  (message "已记录本次回顾（仅内存）；辅助程度由你决定，不自动调整"))

(provide 'crosslang)
;;; crosslang.el ends here
