;;; doom-packages.el --- Optional pinned adapter dependencies -*- lexical-binding: t; -*-
;; SPDX-License-Identifier: GPL-3.0-or-later
;; Load from Doom's packages.el, then run doom sync. Installs all three adapters.
;; Pins match test/dependencies.json; update them together after compatibility tests.
;; These do not install or authenticate Claude Code or an ACP provider.

(package! agent-shell
  :recipe (:type git :host nil :repo "https://github.com/xenodium/agent-shell.git")
  :pin "ae31cf850b3a06178d28e6be72311991ee680ee9")
(package! acp
  :recipe (:type git :host nil :repo "https://github.com/xenodium/acp.el.git")
  :pin "242cef63d76cc1073485847f67a21f6d8406d158")
(package! shell-maker
  :recipe (:type git :host nil :repo "https://github.com/xenodium/shell-maker.git")
  :pin "dcc05a8cf24eb62f2f611fd2d009a161fada5f6e")
(package! eat
  :recipe (:type git :host nil :repo "https://codeberg.org/akib/emacs-eat.git"
                 :files ("*.el" ("term" "term/*.el")
                         "*.texi" "*.ti" ("terminfo/e" "terminfo/e/*")
                         ("terminfo/65" "terminfo/65/*")
                         ("integration" "integration/*")
                         (:exclude ".dir-locals.el" "*-tests.el")))
  :pin "c8d54d649872bfe7b2b9f49ae5c2addbf12d3b99")
(package! compat
  :recipe (:type git :host nil :repo "https://github.com/emacs-compat/compat.git")
  :pin "90880f81419577e1d3f68424d2a3adf31e6d663e")
(package! vterm
  :recipe (:type git :host nil :repo "https://github.com/akermu/emacs-libvterm.git")
  :pin "70921114908ebb260d6686db8cbe2445a64f90a2")
