;;; erc-speedbar.el --- Speedbar support for ERC  -*- lexical-binding: t; -*-

;; Copyright (C) 2001-2004, 2006-2023 Free Software Foundation, Inc.

;; Author: Mario Lang <mlang@delysid.org>
;; Contributor: Eric M. Ludlam <zappo@gnu.org>
;; Maintainer: Amin Bandali <bandali@gnu.org>, F. Jason Park <jp@neverwas.me>
;; URL: https://www.emacswiki.org/emacs/ErcSpeedbar

;; This file is part of GNU Emacs.

;; GNU Emacs is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; GNU Emacs is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with GNU Emacs.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This module provides integration of ERC into the Speedbar.

;;; TODO / ideas:

;; * Write intelligent update function:
;;   update-channel, update-nick, remove-nick-from-channel, ...
;; * Use indicator-strings for op/voice
;; * Extract/convert face notes field from bbdb if available
;; * Write tests that run in a term-mode subprocess
;;
;;; Code:

(require 'erc)
(require 'erc-goodies)
(require 'erc-button)
(require 'speedbar)

;;; Customization:

(defgroup erc-speedbar nil
  "Speedbar integration for ERC.
To open an ERC-flavored speedbar in a separate frame, run the
command `erc-speedbar-browser'.  To use a window-based proxy
instead, run \\[erc-nickbar-mode] in a connected ERC buffer or
put `nickbar' in `erc-modules' before connecting.  See Info
node `(speedbar) Top' for more about the underlying integration."
  :group 'erc)

(defcustom erc-speedbar-nicknames-window-width 18
  "Default width of the nicknames sidebar (in columns)."
  :package-version '(ERC . "5.6") ; FIXME sync on release
  :type 'integer)

(defcustom erc-speedbar-sort-users-type 'activity
  "How channel nicknames are sorted.

`activity'     - Sort users by channel activity
`alphabetical' - Sort users alphabetically
nil            - Do not sort users"
  :type '(choice (const :tag "Sort users by channel activity" activity)
		 (const :tag "Sort users alphabetically" alphabetical)
		 (const :tag "Do not sort users" nil)))

(defcustom erc-speedbar-hide-mode-topic 'headerline
  "Hide mode and topic lines."
  :package-version '(ERC . "5.6") ; FIXME sync on release
  :type '(choice (const :tag "Always show" nil)
                 (const :tag "Always hide" t)
                 (const :tag "Omit when headerline visible" headerline)))

(defcustom erc-speedbar-my-nick-face t
  "A face to use for your nickname.
When the value is t, ERC uses `erc-current-nick-face' if
`erc-match' has been loaded and `erc-my-nick-face' otherwise.
When using the `nicks' module, you can see your nick as it
appears to others by coordinating with the option
`erc-nicks-skip-faces'."
  :package-version '(ERC . "5.6") ; FIXME sync on release
  :type '(choice face (const :tag "Current nick or own speaker face" t)))

(defvar erc-speedbar-key-map nil
  "Keymap used when in erc display mode.")

(defun erc-install-speedbar-variables ()
  "Install those variables used by speedbar to enhance ERC."
  (if erc-speedbar-key-map
      nil
    (setq erc-speedbar-key-map (speedbar-make-specialized-keymap))

    ;; Basic tree features
    (define-key erc-speedbar-key-map "e" #'speedbar-edit-line)
    (define-key erc-speedbar-key-map "\C-m" #'speedbar-edit-line)
    (define-key erc-speedbar-key-map "+" #'speedbar-expand-line)
    (define-key erc-speedbar-key-map "=" #'speedbar-expand-line)
    (define-key erc-speedbar-key-map "-" #'speedbar-contract-line))

  (speedbar-add-expansion-list '("ERC" erc-speedbar-menu-items
				 erc-speedbar-key-map
				 erc-speedbar-server-buttons))
  (speedbar-add-mode-functions-list
   '("ERC" (speedbar-item-info . erc-speedbar-item-info))))

(defvar erc-speedbar-menu-items
  '(["Goto buffer" speedbar-edit-line t]
    ["Expand Node" speedbar-expand-line
     (save-excursion (beginning-of-line)
		     (looking-at "[0-9]+: *.\\+. "))]
    ["Contract Node" speedbar-contract-line
     (save-excursion (beginning-of-line)
		     (looking-at "[0-9]+: *.-. "))])
  "Additional menu-items to add to speedbar frame.")

;;; ERC hierarchy display method
;;;###autoload
(defun erc-speedbar-browser ()
  "Initialize speedbar to display an ERC browser.
This will add a speedbar major display mode."
  (interactive)
  (require 'speedbar)
  (erc-install-speedbar-variables)
  ;; Make sure that speedbar is active
  (speedbar-frame-mode 1)
  ;; Now, throw us into Info mode on speedbar.
  (speedbar-change-initial-expansion-list "ERC")
  (speedbar-get-focus))

(defun erc-speedbar-buttons (buffer)
  "Create buttons for speedbar in BUFFER."
  (erase-buffer)
  (let (serverp chanp queryp)
    (with-current-buffer buffer
      (setq serverp (erc-server-buffer-p))
      (setq chanp (erc-channel-p (erc-default-target)))
      (setq queryp (erc-query-buffer-p)))
    (cond (serverp
	   (erc-speedbar-channel-buttons nil 0 buffer))
	  (chanp
	   (erc-speedbar-insert-target buffer 0)
	   (forward-line -1)
	   (erc-speedbar-expand-channel "+" buffer 0))
	  (queryp
	   (erc-speedbar-insert-target buffer 0))
	  (t (ignore)))))

(defun erc-speedbar-server-buttons (_directory depth)
  "Insert the initial list of servers you are connected to."
  (let ((servers (erc-buffer-list
		  (lambda ()
		    (eq (current-buffer)
			(process-buffer erc-server-process))))))
    (when servers
      (speedbar-with-writable
	(dolist (server servers)
	  (speedbar-make-tag-line
	   'bracket ?+ 'erc-speedbar-expand-server server
	   (buffer-name server) 'erc-speedbar-goto-buffer server nil
	   depth))
	t))))

(defun erc-speedbar-expand-server (text server indent)
  (cond ((string-search "+" text)
	 (speedbar-change-expand-button-char ?-)
	 (if (speedbar-with-writable
	       (save-excursion
		 (end-of-line) (forward-char 1)
		 (erc-speedbar-channel-buttons nil (1+ indent) server)))
	     (speedbar-change-expand-button-char ?-)
	   (speedbar-change-expand-button-char ??)))
	(;; we have to contract this node
         (string-search "-" text)
	 (speedbar-change-expand-button-char ?+)
	 (speedbar-delete-subblock indent))
	(t (error "Ooops... not sure what to do")))
  (speedbar-center-buffer-smartly))

(defun erc-speedbar-channel-buttons (_directory depth server-buffer)
  (when (get-buffer server-buffer)
    (let* ((proc (with-current-buffer server-buffer erc-server-process))
	   (targets (erc-buffer-list
		     (lambda ()
		       (not (eq (process-buffer erc-server-process)
				(current-buffer))))
		     proc)))
      (when targets
	(speedbar-with-writable
	  (dolist (target targets)
	    (erc-speedbar-insert-target target depth))
	  t)))))

(defun erc-speedbar-insert-target (buffer depth)
  (if (erc--target-channel-p (buffer-local-value 'erc--target buffer))
      (progn
        (speedbar-make-tag-line
         'bracket ?+ 'erc-speedbar-expand-channel buffer
         (erc--target-string (buffer-local-value 'erc--target buffer))
         'erc-speedbar-goto-buffer buffer nil
         depth)
        (save-excursion
          (forward-line -1)
          (let ((table (buffer-local-value 'erc-channel-users buffer)))
            (speedbar-add-indicator (format "(%d)" (hash-table-count table)))
            (rx "(" (+ (any "0-9")) ")"))))
    ;; Query target
    (speedbar-make-tag-line
     nil nil nil nil
     (buffer-name buffer) 'erc-speedbar-goto-buffer buffer nil
     depth)))

(defun erc-speedbar-expand-channel (text channel indent)
  "For the line matching TEXT, in CHANNEL, expand or contract a line.
INDENT is the current indentation level."
  (cond
   ((string-search "+" text)
    (speedbar-change-expand-button-char ?-)
    (speedbar-with-writable
     (save-excursion
       (end-of-line) (forward-char 1)
       (let ((modes (with-current-buffer channel
		      (concat (apply #'concat
				     erc-channel-modes)
			      (cond
			       ((and erc-channel-user-limit
				     erc-channel-key)
				(if erc-show-channel-key-p
				    (format "lk %.0f %s"
					    erc-channel-user-limit
					    erc-channel-key)
				  (format "kl %.0f" erc-channel-user-limit)))
			       (erc-channel-user-limit
				;; Emacs has no bignums
				(format "l %.0f" erc-channel-user-limit))
			       (erc-channel-key
				(if erc-show-channel-key-p
				    (format "k %s" erc-channel-key)
				  "k"))
			       (t "")))))
	     (topic (erc-controls-interpret
		     (with-current-buffer channel erc-channel-topic))))
	 (speedbar-make-tag-line
	  'angle ?i nil nil
	  (concat "Modes: +" modes) nil nil nil
	  (1+ indent))
	 (unless (string= topic "")
	   (speedbar-make-tag-line
	    'angle ?i nil nil
	    (concat "Topic: " topic) nil nil nil
	    (1+ indent)))
         (unless (pcase erc-speedbar-hide-mode-topic
                   ('nil 'show)
                   ('headerline (null erc-header-line-format)))
           (save-excursion
             (goto-char (point-max))
             (forward-line (if (string= topic "") -1 -2))
             (put-text-property (pos-bol) (point-max) 'invisible t)))
	 (let ((names (cond ((eq erc-speedbar-sort-users-type 'alphabetical)
			     (erc-sort-channel-users-alphabetically
			      (with-current-buffer channel
				(erc-get-channel-user-list))))
			    ((eq erc-speedbar-sort-users-type 'activity)
			     (erc-sort-channel-users-by-activity
			      (with-current-buffer channel
				(erc-get-channel-user-list))))
			    (t (with-current-buffer channel
				 (erc-get-channel-user-list))))))
	   (when names
	     (speedbar-with-writable
	      (dolist (entry names)
                (erc-speedbar-insert-user entry ?+ (1+ indent) channel)))))))))
   ((string-search "-" text)
    (speedbar-change-expand-button-char ?+)
    (speedbar-delete-subblock indent))
   (t (error "Ooops... not sure what to do")))
  (speedbar-center-buffer-smartly))

(defvar erc-speedbar--nick-face-function #'erc-speedbar--highlight-self-and-ops
  "Function called when finding a face for fontifying nicks.
Called with the proposed nick, the `erc-server-user', and the
`erc-channel-user'.  Should return any valid face, possibly
composed or anonymous, or nil.")

(defun erc-speedbar--highlight-self-and-ops (buffer user cuser)
  "Highlight own nick and op'd users in the speedbar."
  (with-current-buffer buffer
    (if (erc-current-nick-p (erc-server-user-nickname user))
        (pcase erc-speedbar-my-nick-face
          ('t (if (facep 'erc-current-nick-face)
                  'erc-current-nick-face
                'erc-my-nick-face))
          (v v))
      ;; FIXME overload `erc-channel-user-owner-p' and friends to
      ;; accept an `erc-channel-user' object and replace this unrolled
      ;; stuff with a single call to `erc-get-user-mode-prefix'.
      (and cuser (or (erc-channel-user-owner cuser)
                     (erc-channel-user-admin cuser)
                     (erc-channel-user-op cuser)
                     (erc-channel-user-halfop cuser)
                     (erc-channel-user-voice cuser))
           erc-button-nickname-face))))

(defun erc-speedbar--on-click (nick sbtoken _indent)
  ;; 0: finger, 1: name, 2: info, 3: buffer-name
  (with-current-buffer (nth 3 sbtoken)
    (erc-nick-popup (string-trim-left nick "[~&@%+]+"))))

(defun erc-speedbar-insert-user (entry exp-char indent &optional buffer)
  "Insert one user based on the channel member list ENTRY.
Expect EXP-CHAR to be the expansion character to use, INDENT the
current indentation level, and BUFFER the associated channel or
query buffer.  Set the `speedbar-function' text property to
`erc-speedbar--on-click', which is called with the formatted
nick, a so-called \"token\", and the indent level.  The token is
a list of four items: the userhost, the GECOS, the current
`erc-server-user' info slot, and the associated buffer."
  (let* ((user (car entry))
	 (cuser (cdr entry))
	 (nick (erc-server-user-nickname user))
	 (host (erc-server-user-host user))
	 (info (erc-server-user-info user))
	 (login (erc-server-user-login user))
	 (name (erc-server-user-full-name user))
	 (voice (and cuser (erc-channel-user-voice cuser)))
	 (op (and cuser (erc-channel-user-op cuser)))
	 (nick-str (concat (if op "@" "") (if voice "+" "") nick))
	 (finger (concat login (when (or login host) "@") host))
         (sbtoken (list finger name info (buffer-name buffer))))
    (if (or login host name info) ; we want to be expandable
	(speedbar-make-tag-line
	 'bracket ?+ 'erc-speedbar-expand-user sbtoken
         nick-str #'erc-speedbar--on-click sbtoken
         (funcall erc-speedbar--nick-face-function buffer user cuser)
	 indent)
      (when (equal exp-char ?-)
	(forward-line -1)
	(erc-speedbar-expand-user "+" (list finger name info) indent))
      (speedbar-make-tag-line
       'statictag ?? nil nil
       nick-str nil nil nil
       indent))))

(defun erc-speedbar-update-channel (buffer)
  "Update the speedbar information about a ERC buffer.
The update is only done when the channel is actually expanded already."
  ;; This is only a rude hack and doesn't care about multiserver usage
  ;; yet, consider this a brain storming, better ideas?
  (with-current-buffer speedbar-buffer
    (save-excursion
      (goto-char (point-min))
      (when (re-search-forward (concat "^1: *.+. *"
				       (regexp-quote (buffer-name buffer)))
			       nil t)
	(beginning-of-line)
	(speedbar-delete-subblock 1)
	(erc-speedbar-expand-channel "+" buffer 1)))))

(defun erc-speedbar-expand-user (text token indent)
  (cond ((string-search "+" text)
	 (speedbar-change-expand-button-char ?-)
	 (speedbar-with-writable
	   (save-excursion
	     (end-of-line) (forward-char 1)
	     (let ((finger (nth 0 token))
		   (name (nth 1 token))
		   (info (nth 2 token)))
	       (when finger
		 (speedbar-make-tag-line
		  nil nil nil nil
		  finger nil nil nil
		  (1+ indent)))
	       (when name
		 (speedbar-make-tag-line
		  nil nil nil nil
		  name nil nil nil
		  (1+ indent)))
	       (when info
		 (speedbar-make-tag-line
		  nil nil nil nil
		  info nil nil nil
		  (1+ indent)))))))
	((string-search "-" text)
	 (speedbar-change-expand-button-char ?+)
	 (speedbar-delete-subblock indent))
	(t (error "Ooops... not sure what to do")))
  (speedbar-center-buffer-smartly))

(defun erc-speedbar-goto-buffer (_text buffer _indent)
  "When user clicks on TEXT, goto an ERC buffer.
The INDENT level is ignored."
  (if (featurep 'dframe)
      (progn
	(dframe-select-attached-frame speedbar-frame)
	(let ((bwin (get-buffer-window buffer 0)))
	  (if bwin
	      (progn
		(select-window bwin)
		(raise-frame (window-frame bwin)))
	    (if dframe-power-click
		(let ((pop-up-frames t))
		  (select-window (display-buffer buffer)))
	      (dframe-select-attached-frame speedbar-frame)
	      (switch-to-buffer buffer)))))
    (let ((bwin (get-buffer-window buffer 0)))
      (if bwin
	  (progn
	    (select-window bwin)
	    (raise-frame (window-frame bwin)))
	(if speedbar-power-click
	    (let ((pop-up-frames t)) (select-window (display-buffer buffer)))
	  (dframe-select-attached-frame speedbar-frame)
	  (switch-to-buffer buffer))))))

(defun erc-speedbar-line-text ()
  "Return the text for the item on the current line."
  (beginning-of-line)
  (when (re-search-forward "[]>] " nil t)
    (buffer-substring-no-properties (point) (line-end-position))))

(defun erc-speedbar-item-info ()
  "Display information about the current buffer on the current line."
  (let ((data (speedbar-line-token))
	(txt (erc-speedbar-line-text)))
    (cond ((and data (listp data))
	   (message "%s: %s" txt (car data)))
	  ((bufferp data)
	   (message "Channel: %s" txt))
	  (t
	   (message "%s" txt)))))


;;;; Status-sidebar integration

(defvar erc-track-mode)
(defvar erc-track--switch-fallback-blockers)
(defvar erc-status-sidebar-buffer-name)
(declare-function erc-status-sidebar-set-window-preserve-size
                  "erc-status-sidebar" nil)
(declare-function erc-status-sidebar-mode--unhook "erc-status-sidebar" nil)

(defvar erc-speedbar--buffer-options
  '((speedbar-update-flag . t)
    (speedbar-use-images . nil)
    (speedbar-hide-button-brackets-flag . t)))

(defvar erc-speedbar--hidden-speedbar-frame nil)

(defun erc-speedbar--emulate-sidebar-set-window-preserve-size ()
  (let ((erc-status-sidebar-buffer-name (buffer-name speedbar-buffer))
        (display-buffer-overriding-action
         `(display-buffer-in-side-window
           . ((side . right)
              (window-width . ,erc-speedbar-nicknames-window-width)))))
    (erc-status-sidebar-set-window-preserve-size)
    (when-let ((window (get-buffer-window speedbar-buffer)))
      (set-window-parameter window 'no-other-window nil)
      (internal-show-cursor window t))))

(defun erc-speedbar--status-sidebar-mode--unhook ()
  "Remove hooks installed by `erc-status-sidebar-mode'."
  (remove-hook 'window-configuration-change-hook
               #'erc-speedbar--emulate-sidebar-set-window-preserve-size))

(defun erc-speedbar--emulate-sidebar ()
  (require 'erc-status-sidebar)
  (cl-assert speedbar-frame)
  (cl-assert (eq speedbar-buffer (current-buffer)))
  (cl-assert (eq speedbar-frame (selected-frame)))
  (setq erc-speedbar--hidden-speedbar-frame speedbar-frame
        dframe-controlled #'erc-speedbar--dframe-controlled)
  (add-hook 'window-configuration-change-hook
            #'erc-speedbar--emulate-sidebar-set-window-preserve-size nil t)
  (add-hook 'kill-buffer-hook
            #'erc-speedbar--status-sidebar-mode--unhook nil t)
  (with-current-buffer speedbar-buffer
    (pcase-dolist (`(,var . ,val) erc-speedbar--buffer-options)
      (set (make-local-variable var) val)))
  (when (memq 'nicks erc-modules)
    (with-current-buffer speedbar-buffer
      (add-function :around (local 'erc-speedbar--nick-face-function)
                    #'erc-speedbar--compose-nicks-face))))

(defun erc-speedbar--toggle-nicknames-sidebar (arg)
  (let ((force (numberp arg)))
    (if speedbar-buffer
        (progn
          (cl-assert (buffer-live-p speedbar-buffer))
          (if (or (and force (< arg 0))
                  (and (not force) (get-buffer-window speedbar-buffer nil)))
              (erc-speedbar-close-nicknames-window nil)
            (when (or (not force) (>= arg 0))
              (with-selected-frame speedbar-frame
                (erc-speedbar--emulate-sidebar-set-window-preserve-size)))))
      (when (or (not force) (>= arg 0))
        (let ((speedbar-frame-parameters (backquote-list*
                                          '(visibility . nil)
                                          '(no-other-frame . t)
                                          speedbar-frame-parameters))
              (speedbar-after-create-hook #'erc-speedbar--emulate-sidebar))
          (erc-speedbar-browser)
          ;; If we put the remaining parts in the "create hook" along
          ;; with everything else, the frame with `window-main-window'
          ;; gets raised and steals focus if you've switched away from
          ;; Emacs in the meantime.
          (make-frame-invisible speedbar-frame)
          (select-frame (setq speedbar-frame (previous-frame)))
          (erc-speedbar--emulate-sidebar-set-window-preserve-size))))))

(defun erc-speedbar--ensure (&optional force)
  (when (or (erc-server-buffer) force)
    (when erc-track-mode
      (cl-pushnew '(derived-mode . speedbar-mode)
                  erc-track--switch-fallback-blockers :test #'equal))
    (erc-speedbar--toggle-nicknames-sidebar +1)
    (speedbar-enable-update)))

;;;###autoload(autoload 'erc-nickbar-mode "erc-speedbar" nil t)
(define-erc-module nickbar nil
  "Show nicknames in a side window.
When enabling, create a speedbar session if one doesn't exist and
show its buffer in an `erc-status-sidebar' window instead of a
separate frame.  When disabling, close the window or, with a
negative prefix arg, destroy the session.

WARNING: this module may produce unwanted side effects, like the
raising of frames or the stealing of input focus.  If you witness
such an occurrence, and can reproduce it, please file a bug
report with \\[erc-bug]."
  ((add-hook 'erc--setup-buffer-hook #'erc-speedbar--ensure)
   (erc-speedbar--ensure)
   (unless (or erc--updating-modules-p
               (and-let* ((speedbar-buffer)
                          (win (get-buffer-window speedbar-buffer 'all-frames))
                          ((eq speedbar-frame (window-frame win))))))
     (if speedbar-buffer
         (erc-speedbar--ensure 'force)
       (setq erc-nickbar-mode nil)
       (when (derived-mode-p 'erc-mode)
         (erc-error "Not initializing `erc-nickbar-mode' in %s"
                    (current-buffer))))))
  ((remove-hook 'erc--setup-buffer-hook #'erc-speedbar--ensure)
   (speedbar-disable-update)
   (when erc-track-mode
     (setq erc-track--switch-fallback-blockers
           (remove '(derived-mode . speedbar-mode)
                   erc-track--switch-fallback-blockers)))
   (erc-speedbar--toggle-nicknames-sidebar -1)
   (when-let ((arg erc--module-toggle-prefix-arg)
              ((numberp arg))
              ((< arg 0)))
     (erc-speedbar-close-nicknames-window 'kill))))

(defun erc-speedbar--dframe-controlled (arg)
  (when (and erc-speedbar--hidden-speedbar-frame (numberp arg) (< arg 0))
    (when erc-nickbar-mode
      (erc-nickbar-mode -1))
    (setq speedbar-frame erc-speedbar--hidden-speedbar-frame
          erc-speedbar--hidden-speedbar-frame nil)
    ;; It's unknown whether leaving the frame invisible interferes
    ;; with the upstream teardown procedure.
    (when (display-graphic-p)
      (make-frame-visible speedbar-frame))
    (speedbar-frame-mode arg)
    (when speedbar-buffer
      (kill-buffer speedbar-buffer)
      (setq speedbar-buffer nil))))

(defun erc-speedbar-toggle-nicknames-window-lock ()
  "Toggle whether nicknames window is selectable with \\[other-window]."
  (interactive)
  (unless erc-nickbar-mode
    (user-error "`erc-nickbar-mode' inactive"))
  (when-let ((window (get-buffer-window speedbar-buffer)))
    (let ((val (window-parameter window 'no-other-window)))
      (set-window-parameter window 'no-other-window (not val))
      (message "nick-window: %s" (if val "selectable" "protected")))))

(defun erc-speedbar-close-nicknames-window (kill)
  (interactive "P")
  (if kill
      (with-current-buffer speedbar-buffer
        (dframe-close-frame)
        (cl-assert (not erc-nickbar-mode))
        (setq erc-speedbar--hidden-speedbar-frame nil))
    (dolist (window (get-buffer-window-list speedbar-buffer nil t))
      (unless (frame-root-window-p window)
        (when erc-speedbar--hidden-speedbar-frame
          (cl-assert (not (eq (window-frame window)
                              erc-speedbar--hidden-speedbar-frame))))
        (delete-window window)))))


;;;; Nicks integration

(declare-function erc-nicks--highlight "erc-nicks" (nickname &optional face))

(defun erc-speedbar--compose-nicks-face (orig buffer user cuser)
  (require 'erc-nicks)
  (let ((rv (funcall orig buffer user cuser)))
    (if-let ((nick (erc-server-user-nickname user))
             (face (with-current-buffer buffer
                     (erc-nicks--highlight nick rv)))
             ((not (eq face erc-button-nickname-face))))
        (cons face (ensure-list rv))
      rv)))


(provide 'erc-speedbar)
;;; erc-speedbar.el ends here
;;
;; Local Variables:
;; generated-autoload-file: "erc-loaddefs.el"
;; End:
