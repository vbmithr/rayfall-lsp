;;; rayfall-lsp-ui.el --- On-demand Rayfall inspection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; Load this file to keep Rayfall Eglot inspection and Company completion
;; on demand.  C-c C-d requests a read-only inspection popup; M-TAB still requests completion.

;;; Code:
(require 'eglot)

(defun rayfall-lsp-hide-inspection ()
  "Dismiss the inspection popup before the next command."
  (when (fboundp 'posframe-hide)
    (posframe-hide " *Rayfall inspection*"))
  (remove-hook 'pre-command-hook #'rayfall-lsp-hide-inspection))

(defun rayfall-lsp--display-inspection (documentation windowp)
  "Display DOCUMENTATION near point, or in a help window if WINDOWP."
  (if (and (not windowp) (require 'posframe nil t) (posframe-workable-p))
      (progn
        (posframe-show
         " *Rayfall inspection*"
         :string documentation :position (point)
         :max-width 90 :max-height 18
         :left-fringe 8 :right-fringe 8 :internal-border-width 1
         :background-color (face-background (if (facep 'company-tooltip) 'company-tooltip 'tooltip) nil t)
         :foreground-color (face-foreground (if (facep 'company-tooltip) 'company-tooltip 'tooltip) nil t)
         :accept-focus nil)
        (add-hook 'pre-command-hook #'rayfall-lsp-hide-inspection))
    (with-help-window "*Rayfall details*"
      (princ documentation))))

(defun rayfall-lsp-describe-at-point (&optional windowp)
  "Request semantic details in a read-only popup near point.
With a prefix argument WINDOWP, use a help window for longer details.
Fall back to a help window when posframe or graphical display is unavailable."
  (interactive "P")
  (unless (eglot-managed-p)
    (user-error "This buffer is not managed by Eglot"))
  (require 'company nil t)
  (rayfall-lsp-hide-inspection)
  (let ((origin (current-buffer))
        (position (point))
        (tick (buffer-chars-modified-tick)))
    (eglot-hover-eldoc-function
     (lambda (documentation &rest _properties)
       ;; An asynchronous reply must not follow the cursor or an edit.
       (when (and (eq (current-buffer) origin)
                  (= (point) position)
                  (= (buffer-chars-modified-tick) tick))
         (if (not (and documentation (> (length documentation) 0)))
             (message "No static information at point")
           (rayfall-lsp--display-inspection documentation windowp)))))))

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
