;;; crosslang-init.el --- Isolated communication entry point -*- lexical-binding: t; -*-
;; Portable entry. Loading never enables a mode or starts a model server.
(add-to-list 'load-path (file-name-directory (or load-file-name buffer-file-name)))
(require 'crosslang-gptel)
(require 'crosslang-local)
(require 'crosslang-live)
(autoload 'crosslang-pair-mode "crosslang-pair" nil t)
;; Same column-based Pretty Hydra as M-o; no menu dependency loads at startup.
(require 'crosslang-leader)
;; Keep the user's options: Python, dictionaries, model and port are customized
;; outside this file. Defaults never start or download anything.
;; Deliberately no gptel hook: M-x crosslang-gptel-enable in your current chat.
(provide 'crosslang-init)
