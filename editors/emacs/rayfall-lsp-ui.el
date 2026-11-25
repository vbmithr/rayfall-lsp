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

(defcustom rayfall-lsp-engine-timeout 3
  "Seconds a throwaway engine may run to look up a builtin's signature."
  :type 'number :group 'rayfall-lsp-ui)

(defvar rayfall-completion-timeout)
(defvar rayfall-repl-buffer)
(defvar rayfall-repl--pending-eval)
(defvar rayfall-repl--completion-request)
(defvar rayfall-repl--completion-result)
(defvar rayfall-program)
(defvar rayfall-program-arguments)
(defvar rayfall--repl-sentinel)
(defvar rayfall--repl-sentinel-command)
(declare-function rayfall--cancel-prompt-timer "rayfall-mode")
(declare-function rayfall--complete-completion-request "rayfall-mode")

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

;;; Builtin signatures

(defvar rayfall-lsp--raw-reply nil
  "Non-nil in a REPL buffer while a request wants its reply unparsed.")
(make-variable-buffer-local 'rayfall-lsp--raw-reply)

(define-advice rayfall--parse-completions
    (:around (parse output) rayfall-lsp-raw-reply)
  "Return OUTPUT as text for a signature request, which is not a symbol vector.
The flag is buffer-local because the reply may be consumed by the process
filter, outside the dynamic extent of the request."
  (if rayfall-lsp--raw-reply
      ;; Drop only the final line terminator: an empty last field is data.
      (replace-regexp-in-string "\r?\n\\'" "" output)
    (funcall parse output)))

(defconst rayfall-lsp--name-regexp "\\`[A-Za-z0-9_.?!+*/<=>%~#$&:^|-]+\\'"
  "Names sent to the REPL.  Anything else is never interpolated into code.")

(defun rayfall-lsp--session-signature (name)
  "Return (KIND BUILTIN USAGE) for NAME from the idle live session, or nil.
Ask `.repl.signature', which evaluates nothing and calls nothing."
  (when (and (string-match-p rayfall-lsp--name-regexp name)
             (fboundp 'rayfall--repl-live-p)
             (rayfall--repl-live-p))
    (with-current-buffer rayfall-repl-buffer
      (unless (or rayfall-repl--pending-eval rayfall-repl--completion-request)
        (rayfall--cancel-prompt-timer)
        (let* ((process (get-buffer-process (current-buffer)))
               (deadline (+ (float-time) rayfall-lsp-live-completion-timeout))
               (signature (format "(.repl.signature (quote %s))" name)))
          (setq rayfall-lsp--raw-reply t
                rayfall-repl--completion-result nil
                rayfall-repl--completion-request
                (list (copy-marker (process-mark process))
                      rayfall--repl-sentinel))
          (unwind-protect
              (progn
                (comint-send-string
                 process
                 (concat
                  (mapconcat (lambda (field)
                               (format "(println (at %s (quote %s)))\n"
                                       signature field))
                             '("kind" "builtin" "usage") "")
                  rayfall--repl-sentinel-command))
                (while (and rayfall-repl--completion-request
                            (< (float-time) deadline))
                  (accept-process-output process 0.05))
                (when rayfall-repl--completion-request
                  (rayfall--complete-completion-request)))
            ;; A failed or partial reply must never block later evaluation.
            (when rayfall-repl--completion-request
              (set-marker (car rayfall-repl--completion-request) nil)
              (setq rayfall-repl--completion-request nil))
            (setq rayfall-lsp--raw-reply nil))
          (rayfall-lsp--parse-signature rayfall-repl--completion-result))))))

(defun rayfall-lsp--oneshot-signature (name)
  "Return (KIND BUILTIN USAGE) for NAME from a throwaway engine process, or nil.
Used when no Rayfall session is running.  The engine reads the three
`.repl.signature' queries from stdin and exits at end of input."
  (when (and (string-match-p rayfall-lsp--name-regexp name)
             (executable-find rayfall-program))
    (let ((input (mapconcat
                  (lambda (field)
                    (format "(println (at (.repl.signature (quote %s)) (quote %s)))\n"
                            name field))
                  '("kind" "builtin" "usage") ""))
          (limit (executable-find "timeout")))
      (with-temp-buffer
        (ignore-errors
          (apply #'call-process-region input nil
                 (or limit rayfall-program) nil t nil
                 (append (and limit
                              (list (format "%s" rayfall-lsp-engine-timeout)
                                    rayfall-program))
                         rayfall-program-arguments)))
        (rayfall-lsp--parse-signature (buffer-string))))))

(defun rayfall-lsp--signature (name)
  "Return (KIND BUILTIN USAGE) for builtin NAME, or nil.
Prefer an idle live session, which may hold rebinds; else ask a fresh engine."
  (or (rayfall-lsp--session-signature name)
      (rayfall-lsp--oneshot-signature name)))

(defun rayfall-lsp--parse-signature (text)
  "Parse the three reply lines in TEXT into (KIND BUILTIN USAGE), or nil.
An undocumented builtin has an empty usage line."
  (let ((lines (and (stringp text)
                    (split-string (replace-regexp-in-string "\r?\n\\'" "" text)
                                  "\r?\n"))))
    (when (and (= (length lines) 3)
               (string-match-p "\\`'[a-z]+\\'" (string-trim (nth 0 lines))))
      (list (string-remove-prefix "'" (string-trim (nth 0 lines)))
            (string-remove-prefix "'" (string-trim (nth 1 lines)))
            (string-trim (nth 2 lines))))))

(defun rayfall-lsp--describe-signature (name)
  "Return display text for builtin NAME, or nil when NAME is not a builtin."
  (pcase (rayfall-lsp--signature name)
    (`(,kind ,builtin ,usage)
     (when (and (not (equal builtin "")) (member kind '("unary" "binary" "vary")))
       (concat (if (equal builtin name)
                   (format "%s: builtin (%s)" name kind)
                 (format "%s: alias of builtin %s (%s)" name builtin kind))
               (unless (equal usage "") (concat "\n" usage)))))))

(defun rayfall-lsp--name-at-point ()
  "Return the whole name at point, dotted builtins such as `.ipc.open' included.
The mode's syntax table splits at dots, so scan with the completion charset."
  (save-excursion
    (let ((chars "A-Za-z0-9_.?!+*/<=>%~#$&:^|-"))
      (skip-chars-backward chars)
      (let ((start (point)))
        (skip-chars-forward chars)
        (and (< start (point))
             (buffer-substring-no-properties start (point)))))))

(defun rayfall-lsp-find-definition ()
  "Go to the definition of the identifier at point.
A builtin has no source, so show its signature from the live session instead
of failing.  A user binding that shadows a builtin still jumps to its source."
  (interactive)
  (condition-case err
      (call-interactively #'xref-find-definitions)
    (user-error
     (let* ((name (rayfall-lsp--name-at-point))
            (text (and name (not (nth 8 (syntax-ppss)))
                       (rayfall-lsp--describe-signature name))))
       (cond
        (text
         ;; The echo area survives where a popup is hidden, unseen or absent.
         (message "%s" text)
         (rayfall-lsp--display-inspection text nil))
        ;; Without an engine a builtin looks like any other missing name.
        ((not (executable-find rayfall-program))
         (user-error "%s (builtin signatures need `%s' on exec-path; see `rayfall-program')"
                     (error-message-string err) rayfall-program))
        (t (signal (car err) (cdr err))))))))

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
    (local-set-key (kbd "M-.") #'rayfall-lsp-find-definition)
    (local-set-key (kbd "C-c C-d") #'rayfall-lsp-describe-at-point)))

(add-hook 'eglot-managed-mode-hook #'rayfall-lsp-on-demand-setup)

(provide 'rayfall-lsp-ui)
;;; rayfall-lsp-ui.el ends here
