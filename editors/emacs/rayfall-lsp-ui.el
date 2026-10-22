;;; rayfall-lsp-ui.el --- On-demand Rayfall inspection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Load this file to keep Rayfall Eglot inspection and Company completion
;; on demand.  C-c C-d requests details; M-TAB still requests completion.

;;; Code:
(require 'eglot)

(defun rayfall-lsp-describe-at-point ()
  "Request semantic details at point and display them in a help window."
  (interactive)
  (unless (eglot-managed-p)
    (user-error "This buffer is not managed by Eglot"))
  (eglot-hover-eldoc-function
   (lambda (documentation &rest _properties)
     (if (not (and documentation (> (length documentation) 0)))
         (message "No static information at point")
       (with-help-window "*Rayfall details*"
         (princ documentation))))))

(defun rayfall-lsp-on-demand-setup ()
  "Disable automatic semantic requests in Eglot-managed Rayfall buffers."
  (when (and (derived-mode-p 'rayfall-mode) (eglot-managed-p))
    ;; Turning off the timer avoids requests, rather than hiding their output.
    (eldoc-mode -1)
    (setq-local company-idle-delay nil)
    (local-set-key (kbd "C-c C-d") #'rayfall-lsp-describe-at-point)))

(add-hook 'eglot-managed-mode-hook #'rayfall-lsp-on-demand-setup)

(provide 'rayfall-lsp-ui)
;;; rayfall-lsp-ui.el ends here
