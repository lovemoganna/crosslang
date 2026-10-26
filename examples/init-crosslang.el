;;; init-crosslang.el --- Copy and adapt, do not edit package sources -*- lexical-binding: t; -*-
;; Clone this repository to ~/.emacs.d/site-lisp/crosslang first.
(load (expand-file-name "site-lisp/crosslang/crosslang-init.el" user-emacs-directory) nil t)

;; Python uses only its standard library. Set a full path if not on PATH.
(setq crosslang-local-python "python"
      crosslang-local-port 1234
      crosslang-local-model 'auto)
;; Optional: your separately installed StarDict resources.
;; (setq crosslang-local-dictionaries "/path/to/stardict-dictionaries/")

;; An existing revolt-map is automatically supported as SPC -.
;; Otherwise use your existing leader map, or a non-conflicting fallback:
;; (define-key my-leader-map (kbd "-") #'hydra-crosslang/body)
;; (global-set-key (kbd "C-c -") #'hydra-crosslang/body)
