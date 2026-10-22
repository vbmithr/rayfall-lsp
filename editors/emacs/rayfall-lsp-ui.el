;;; rayfall-lsp-ui.el --- On-demand Rayfall inspection -*- lexical-binding: t; -*-

;; SPDX-License-Identifier: MIT
;; Package-Requires: ((emacs "29.1"))

;;; Commentary:
;; C-c C-d requests a read-only inspection popup.  A typed dot starts
;; Company field completion; M-TAB requests other completions manually.

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

(defgroup rayfall-lsp-ui nil
  "Rayfall language-server editor integration."
  :group 'tools)

(defcustom rayfall-lsp-live-completion t
  "Use .repl.complete when an existing Rayfall session is idle.
This covers global names and builtin namespaces, not dictionary fields."
  :type 'boolean :group 'rayfall-lsp-ui)

(defcustom rayfall-lsp-live-completion-timeout 0.15
  "Maximum seconds to wait for live namespace completion."
  :type 'number :group 'rayfall-lsp-ui)

(defvar rayfall-completion-timeout)
(defvar rayfall-repl-buffer)
(defvar rayfall-repl--pending-eval)
(defvar rayfall-repl--completion-request)

(defun rayfall-lsp-live-completion-at-point ()
  "Offer actual names from an existing Rayforce session before static hints.
Do not query dictionary member accesses: .repl.complete does not inspect
those values.  Do not query quoted data, strings, comments, or a busy REPL."
  (when (and rayfall-lsp-live-completion
             (fboundp 'rayfall--repl-live-p)
             (fboundp 'rayfall--completion-candidates)
             (rayfall--repl-live-p)
             (not (nth 8 (syntax-ppss))))
    (let* ((end (point))
           (start (save-excursion
                    (skip-chars-backward "A-Za-z0-9_.?!+*/<=>~-")
                    (point)))
           (prefix (buffer-substring-no-properties start end)))
      (when (and (< start end)
                 (not (memq (char-before start) '(?' ?:)))
                 (or (not (string-match-p "\\." prefix))
                     (string-prefix-p "." prefix))
                 (with-current-buffer rayfall-repl-buffer
                   (not (or rayfall-repl--pending-eval
                            rayfall-repl--completion-request))))
        (condition-case nil
            (let* ((rayfall-completion-timeout
                    rayfall-lsp-live-completion-timeout)
                   (candidates (rayfall--completion-candidates prefix)))
              (when candidates
                (list start end candidates :exclusive 'no
                      :annotation-function (lambda (_) " [Rayforce session]"))))
          (error nil))))))

(defun rayfall-lsp--show-single-candidate ()
  "Keep the Company menu visible even for one matching candidate."
  (setq-local company-frontends
              (mapcar (lambda (frontend)
                        (pcase frontend
                          ('company-childframe-unless-just-one-frontend
                           'company-childframe-frontend)
                          ('company-pseudo-tooltip-unless-just-one-frontend
                           'company-pseudo-tooltip-frontend)
                          (_ frontend)))
                      company-frontends))
  )

(defun rayfall-lsp-complete ()
  "Show completion candidates without immediately inserting a candidate."
  (interactive)
  (if (and (require 'company nil t) (bound-and-true-p company-mode))
      (progn
        (rayfall-lsp--show-single-candidate)
        (let ((company-backends '(company-capf)))
          (company-manual-begin)))
    (completion-at-point)))

(defun rayfall-lsp-complete-after-dot ()
  "Start Company field completion after a typed dot, without inserting text."
  (when (and (eq last-command-event ?.)
             (bound-and-true-p company-mode)
             (eglot-managed-p)
             (not (nth 8 (syntax-ppss)))
             (save-excursion
               (backward-char)
               (and (> (point) (point-min))
                    (not (memq (char-before) '(?\s ?\t ?\n ?\())))))
    (rayfall-lsp-complete)))

(defun rayfall-lsp-on-demand-setup ()
  "Use explicit inspection and automatic completion in Rayfall buffers."
  (when (and (derived-mode-p 'rayfall-mode) (eglot-managed-p))
    ;; Turning off the timer avoids requests, rather than hiding their output.
    (eldoc-mode -1)
    (when (require 'company nil t)
      (setq-local company-idle-delay 0.2)
      (setq-local company-minimum-prefix-length 2)
      (rayfall-lsp--show-single-candidate))
    ;; Replace the legacy fallback, which can start a REPL implicitly.
    (setq-local completion-at-point-functions
                (cons #'rayfall-lsp-live-completion-at-point
                      (remq #'rayfall-lsp-live-completion-at-point
                            (remq #'rayfall-completion-at-point
                                  completion-at-point-functions))))
    (add-hook 'post-self-insert-hook #'rayfall-lsp-complete-after-dot nil t)
    (local-set-key (kbd "M-TAB") #'rayfall-lsp-complete)
    (local-set-key (kbd "C-c C-d") #'rayfall-lsp-describe-at-point)))

(add-hook 'eglot-managed-mode-hook #'rayfall-lsp-on-demand-setup)

(provide 'rayfall-lsp-ui)
;;; rayfall-lsp-ui.el ends here
