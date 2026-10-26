;;; bootstrap.el --- Isolated test dependencies -*- lexical-binding: t; -*-
(setq native-comp-jit-compilation nil native-comp-enable-subr-trampolines nil)
(require 'package)
(package-initialize)
(require 'crosslang-local)
(setq crosslang-local-python (or (getenv "CROSSLANG_TEST_PYTHON") "python"))
