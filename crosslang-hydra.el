;;; crosslang-hydra.el --- Familiar, local language controls -*- lexical-binding: t; -*-

;;; Commentary:
;; Loaded on the first SPC -, using the existing Pretty Hydra installation.
;; Opening or leaving this menu never requests, accepts or sends language text.

;;; Code:
(require 'pretty-hydra)
(require 'crosslang-live)
(autoload 'crosslang-pair-mode "crosslang-pair" nil t)

(defun crosslang-hydra-title ()
  "Describe the source buffer's current assistance state without side effects."
  (concat (propertize "跨语言交流" 'face 'font-lock-keyword-face)
          (format " · %s · 动态%s · %s"
                  crosslang-assistance
                  (if (bound-and-true-p crosslang-live-mode) "开" "关")
                  (cond ((bound-and-true-p crosslang-pair-mode) "双语正文自动维护")
                        (crosslang--review "无提示观察中")
                        (crosslang--proposal "有候选待核对")
                        (t "原文保留")))))

(pretty-hydra-define hydra-crosslang
  (:color blue :quit-key "q" :title (crosslang-hydra-title)
   :hint t)
  ("表达与阅读"
   (("-" crosslang-dwim "智能辅助")
    ("e" crosslang-express "英文表达")
    ("d" crosslang-explain "词句释义")
    ("t" crosslang-translate "完整翻译"))
   "候选处理"
   (("v" crosslang-show-details "查看对照")
    ("RET" crosslang-accept "确认写回")
    ("b" crosslang-insert-bilingual "中英分行写入")
    ("c" crosslang-dismiss "取消候选")
    ("q" nil "退出菜单"))
   "辅助设置"
   (("SPC" crosslang-live-mode "动态预览" :toggle t)
    ("w" crosslang-pair-mode "双语写作" :toggle t)
    ("m" (crosslang-mode (if crosslang-mode -1 1)) "语言辅助" :toggle crosslang-mode)
    ("s" crosslang-set-assistance "辅助程度")
    ("x" crosslang-toggle-context "本地语境" :toggle crosslang-context-enabled)
    ("o" (crosslang-mode -1) "关闭辅助"))
   "自主交流"
   (("r" crosslang-review-start "开始观察")
    ("R" crosslang-review-finish "结束观察")
    ("?" nil "保持菜单" :exit nil)
    ("a" crosslang-accept nil)
    ("<escape>" nil nil)
    ("C-g" nil nil))))

(provide 'crosslang-hydra)
;;; crosslang-hydra.el ends here
