;;; crosslang-leader.el --- Use the existing SPC leader -*- lexical-binding: t; -*-
(require 'crosslang)
(autoload 'hydra-crosslang/body "crosslang-hydra" nil t)

(defun crosslang-leader-install ()
  "Register only the free minus slot of the user's existing leader map.
Never bind SPC itself or install another global leader system."
  (when (and (boundp 'revolt-map) (keymapp revolt-map))
    (let ((old (lookup-key revolt-map (kbd "-"))))
      (unless (memq old '(nil hydra-crosslang/body))
        (user-error "SPC - 已被其他命令占用；CrossLang 未覆盖它"))
      (define-key revolt-map (kbd "-") #'hydra-crosslang/body))))

(crosslang-leader-install)
(with-eval-after-load 'base-evil-keymap (crosslang-leader-install))
(provide 'crosslang-leader)
;;; crosslang-leader.el ends here
