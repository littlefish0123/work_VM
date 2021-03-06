;;; eide-search.el --- Emacs-IDE, search

;; Copyright (C) 2008-2013 Cédric Marie

;; This program is free software: you can redistribute it and/or
;; modify it under the terms of the GNU General Public License as
;; published by the Free Software Foundation, either version 3 of
;; the License, or (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program. If not, see <http://www.gnu.org/licenses/>.

;;; Code:

(provide 'eide-search)

(require 'etags)

(require 'eide-config)
(require 'eide-menu)

;; Test if xcscope is available
(defvar eide-search-use-cscope-flag nil)
(if (locate-library "xcscope")
  (progn
    (require 'xcscope)
    (setq eide-search-use-cscope-flag t)))

(defvar eide-search-find-symbol-definition-flag nil)

;; grep commands should exclude following files:
;; .svn: Subversion directory
;; .git: Git directory
;; *.d: Dependency files
;; *.o.cmd: Kbuild files
;; *.map: Mapping files
;; *.ref, *.new: Emacs-IDE files
;; .emacs.desktop: Emacs files
;; TAGS: Ctags file
;; cscope.files, cscope.output: Cscope files
(defvar eide-search-grep-exclude-options "--devices=skip --exclude-dir=.svn --exclude-dir=.git --exclude=*.d --exclude=*.o.cmd --exclude=*.map --exclude=*.ref --exclude=*.new --exclude=.emacs.desktop --exclude=TAGS --exclude=cscope.files --exclude=cscope.out")

(defvar eide-search-tag-string nil)

;; Shell command for creating tags
(defvar eide-search-create-tags-command "rm -f TAGS ; ctags -eR --links=no")

;; Shell command for creating cscope.files
;; -type f: excludes links
;; cscope.out will be generated on next search
(defvar eide-search-create-cscope-command "rm -f cscope.files cscope.out ; find . -type f \\( -name \"*.[ch]\"  -o -name \"*.cpp\" -o -name \"*.hh\" \\) > cscope.files")
;; cscope -bR

(defvar eide-search-cscope-files-flag nil)

(defvar eide-search-tags-available-flag nil)
(defvar eide-search-cscope-available-flag nil)
(defvar eide-search-cscope-update-database-request-pending-flag nil)

(defvar eide-search-tags-not-ready-string "Tags are not available (creation in progress...)")
(defvar eide-search-cscope-not-ready-string "Cscope list of files is not available (creation in progress...)")
(defvar eide-search-cscope-no-file-string "Cannot use cscope: There is no C/C++ file in this project...")

(defvar eide-search-user-tags-case-fold-search nil)
(defvar eide-search-user-cscope-do-not-update-database nil)

(defvar eide-search-tags-and-cscope-enabled-flag nil)
(defvar eide-search-grep-enabled-flag nil)

;; ----------------------------------------------------------------------------
;; CUSTOMIZATION VARIABLES
;; ----------------------------------------------------------------------------

(defcustom eide-custom-tags-case-sensitive t "Case sensitivity of tag search."
  :tag "Case sensitivity of tag search"
  :type '(choice (const :tag "Don't override" ignore)
                 (const :tag "Case sensitive" t)
                 (const :tag "Case insensitive" nil))
  :set 'eide-i-search-custom-set-tags-case-sensitivity
  :initialize 'custom-initialize-default
  :group 'eide-search)
(defcustom eide-custom-update-cscope-database 'auto "Update of cscope database. Update is necessary when the code has changed. You can update on every search (cscope default behaviour), only on user request, or automatically when a buffer has been edited or refreshed."
  :tag "Update of cscope database"
  :type '(choice (const :tag "Don't override" ignore)
                 (const :tag "Always (on every search)" t)
                 (const :tag "Never (only on user request)" nil)
                 (const :tag "When a buffer has been edited or refreshed" auto))
  :set 'eide-i-search-custom-set-cscope-update
  :initialize 'custom-initialize-default
  :group 'eide-search)

;; ----------------------------------------------------------------------------
;; CUSTOMIZATION FUNCTIONS
;; ----------------------------------------------------------------------------
(defun eide-i-search-custom-set-tags-case-sensitivity (param value)
  "Set tags case sensitivity.
Arguments:
- param: customization parameter.
- value: customization value."
  (set-default param value)
  (if eide-config-ready
    (if (and eide-custom-override-emacs-settings
             (not (equal value 'ignore)))
      (setq tags-case-fold-search (not eide-custom-tags-case-sensitive))
      (setq tags-case-fold-search eide-search-user-tags-case-fold-search))))

(defun eide-i-search-custom-set-cscope-update (param value)
  "Set cscope update.
Arguments:
- param: customization parameter.
- value: customization value."
  (set-default param value)
  (if eide-config-ready
    (if (and eide-custom-override-emacs-settings
             (not (equal value 'ignore)))
      (if (equal value 'auto)
        ;; In "auto" mode, update database for the first search
        (setq eide-search-cscope-update-database-request-pending-flag t))
      (setq cscope-do-not-update-database eide-search-user-cscope-do-not-update-database))))

;; ----------------------------------------------------------------------------
;; INTERNAL FUNCTIONS
;; ----------------------------------------------------------------------------

(defun eide-i-search-tags-sentinel (p-process p-event)
  "Sentinel for \"create tags\" process.
Arguments:
- p-process: process.
- p-event: event."
  (if (string-equal p-event "finished\n")
    (progn
      (setq eide-search-tags-available-flag t)
      (message "Creating tags... done"))))

(defun eide-i-search-cscope-sentinel (p-process p-event)
  "Sentinel for \"create cscope\" process.
Arguments:
- p-process: process.
- p-event: event."
  (if (string-equal p-event "finished\n")
    (progn
      (eide-search-update-cscope-status)
      (setq eide-search-cscope-available-flag t)
      (message "Creating cscope list of files... done"))))

;; ----------------------------------------------------------------------------
;; FUNCTIONS
;; ----------------------------------------------------------------------------

(defun eide-search-apply-customization ()
  "Apply search customization."
  (eide-i-search-custom-set-tags-case-sensitivity 'eide-custom-tags-case-sensitive eide-custom-tags-case-sensitive)
  (if eide-search-use-cscope-flag
    (eide-i-search-custom-set-cscope-update 'eide-custom-update-cscope-database eide-custom-update-cscope-database)))

(defun eide-search-save-emacs-settings ()
  "Save Emacs settings (for search)."
  (setq eide-search-user-tags-case-fold-search tags-case-fold-search)
  (if eide-search-use-cscope-flag
    (setq eide-search-user-cscope-do-not-update-database cscope-do-not-update-database)))

(defun eide-search-set-tags-and-cscope-state (p-state-flag)
  "Disable/enable tags and cscope functions."
  (setq eide-search-tags-and-cscope-enabled-flag p-state-flag))

(defun eide-search-set-grep-state (p-state-flag)
  "Disable/enable grep functions."
  (setq eide-search-grep-enabled-flag p-state-flag))

(defun eide-search-create-tags ()
  "Create tags."
  (message "Creating tags...")
  (setq eide-search-tags-available-flag nil)
  (let ((l-create-tags-exclude-options "") (l-tags-exclude-list (eide-project-get-config-value "tags_exclude")))
    ;; Create a string with the --exclude options if "tags_exclude" list is not
    ;; empty in project configuration
    (if (not (string-equal l-tags-exclude-list ""))
      (setq l-create-tags-exclude-options (concat " " (mapconcat (function (lambda(x) (concat "--exclude=" x))) (split-string l-tags-exclude-list) " "))))
    ;; Execute the command (standard command + --exclude options if any)
    (let ((l-process (start-process-shell-command "create-tags" nil (concat "cd " eide-root-directory " ; " eide-search-create-tags-command l-create-tags-exclude-options))))
      ;; Sentinel is called only when Emacs is idle: it should be safe to register it after subprocess creation
      (set-process-sentinel l-process 'eide-i-search-tags-sentinel))))

(defun eide-search-back-from-tag ()
  "Go back from definition."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (progn
      (eide-windows-select-source-window nil)
      (call-interactively 'pop-tag-mark)
      (eide-menu-update nil))))

(defun eide-search-find-tag (p-string)
  "Go to definition of a symbol.
Argument:
- p-string: symbol."
  (if eide-search-tags-available-flag
    (progn
      (eide-windows-select-source-window nil)
      (find-tag p-string)
      (recenter))
    (message eide-search-tags-not-ready-string)))

(defun eide-search-find-tag-without-prompt ()
  "Go to definition of symbol at cursor position."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (if eide-search-tags-available-flag
      (progn
        ;; Save string in order to call eide-search-find-alternate-tag later on
        (setq eide-search-tag-string (find-tag-default))
        (if eide-search-tag-string
          (eide-search-find-tag eide-search-tag-string)))
      (message eide-search-tags-not-ready-string))))

(defun eide-search-find-tag-with-prompt ()
  "Go to definition of a symbol (prompt for it)."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (if eide-search-tags-available-flag
      (progn
        (eide-windows-select-source-window nil)
        (call-interactively 'find-tag)
        ;; Saving string is necessary for calling eide-search-find-alternate-tag
        ;; later on... but there is no completion!
        ;;(setq eide-search-tag-string (read-string "Go to symbol definition: "))
        ;;(if (string-equal eide-search-tag-string "")
        ;;  (message "Cannot find empty symbol...")
        ;;  (eide-search-find-tag eide-search-tag-string))
        (recenter))
      (message eide-search-tags-not-ready-string))))

(defun eide-search-find-alternate-tag ()
  "Go to alternate definition of previously searched symbol."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (if eide-search-tags-available-flag
      (progn
        (eide-windows-select-source-window nil)
        (call-interactively 'pop-tag-mark)
        (find-tag eide-search-tag-string t)
        (recenter))
      (message eide-search-tags-not-ready-string))))

(defun eide-search-update-cscope-status ()
  "Set cscope status (disabled if list of files is empty)."
  (setq eide-search-cscope-files-flag nil)
  (if (not (equal (nth 7 (file-attributes (concat eide-root-directory "cscope.files"))) 0))
    (setq eide-search-cscope-files-flag t)))

(defun eide-search-create-cscope-list-of-files ()
  "Create cscope list of files."
  (message "Creating cscope list of files...")
  (setq eide-search-cscope-available-flag nil)
  (setq eide-search-cscope-update-database-request-pending-flag t)
  (let ((l-process (start-process-shell-command "create-cscope" nil (concat "cd " eide-root-directory " ; " eide-search-create-cscope-command))))
    ;; Sentinel is called only when Emacs is idle: it should be safe to register it after subprocess creation
    (set-process-sentinel l-process 'eide-i-search-cscope-sentinel)))
;; (cscope-index-files nil))

(defun eide-search-update-cscope-database ()
  "Update cscope database (on next search)."
  (setq eide-search-cscope-update-database-request-pending-flag t)
  (message "On next cscope search, database will be updated"))

(defun eide-search-find-symbol (p-symbol)
  "Find a symbol with cscope.
Argument:
- p-symbol: symbol."
  (if eide-search-cscope-available-flag
    (if eide-search-cscope-files-flag
      (let ((l-result-buffer-name (concat "*cscope*: " p-symbol))
            (l-do-it-flag t))
        (eide-windows-select-output-window)
        (if (get-buffer l-result-buffer-name)
          (if (eide-popup-question-yes-or-no-p "This symbol has already been found... Find again (or use available result)?")
            ;; Delete existing find-symbol buffer
            (kill-buffer l-result-buffer-name)
            (setq l-do-it-flag nil)))
        (if l-do-it-flag
          (progn
            (if (and eide-custom-override-emacs-settings
                     (not (equal eide-custom-update-cscope-database 'ignore)))
              (if (or (equal eide-custom-update-cscope-database 't) eide-search-cscope-update-database-request-pending-flag)
                (progn
                  (setq cscope-do-not-update-database nil)
                  (setq eide-search-cscope-update-database-request-pending-flag nil))
                (setq cscope-do-not-update-database t)))
            (cscope-find-this-symbol p-symbol)
            (save-current-buffer
              (set-buffer "*cscope*")
              (rename-buffer l-result-buffer-name t))
            (eide-menu-build-files-lists))
          (eide-search-view-output-buffer l-result-buffer-name))
        (eide-windows-select-source-window t))
      (message eide-search-cscope-no-file-string))
    (message eide-search-cscope-not-ready-string)))

(defun eide-search-find-symbol-without-prompt ()
  "Find symbol at cursor position with cscope."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (let ((l-string (find-tag-default)))
      (if l-string
        (eide-search-find-symbol l-string)))))

(defun eide-search-find-symbol-with-prompt ()
  "Find a symbol with cscope (prompt for it)."
  (interactive)
  (if eide-search-tags-and-cscope-enabled-flag
    (if eide-search-cscope-available-flag
      (if eide-search-cscope-files-flag
        (let ((l-string (read-string "Find symbol with cscope: ")))
          (if (string-equal l-string "")
            (message "Cannot find empty symbol...")
            (eide-search-find-symbol l-string)))
        (message eide-search-cscope-no-file-string))
      (message eide-search-cscope-not-ready-string))))

(defun eide-search-grep-local (p-string)
  "Grep a string in current directory.
Argument:
- p-string: string."
  (eide-windows-select-source-window t)
  (let ((l-buffer-directory (file-name-directory (buffer-file-name)))
        (l-result-buffer-name (concat "*grep (local)*: " p-string "    (in " (eide-project-get-short-directory default-directory) ")"))
        (l-do-it-flag t))
    (if (get-buffer l-result-buffer-name)
      (if (eide-popup-question-yes-or-no-p "This string has already been searched... Search again (or use available search result)?")
        ;; Delete existing grep buffer
        (kill-buffer l-result-buffer-name)
        (setq l-do-it-flag nil)))
    (if l-do-it-flag
      (progn
        ;; grep options: I (no binary), n (show line number), e (pattern may start with '-')
        ;; 2> /dev/null is used to hide warnings about missing files
        ;; 'cd' is used first, in case shell init changes current directory
        (grep-find (concat "echo ; cd " l-buffer-directory " ; grep -In " eide-search-grep-exclude-options " -e \"" p-string "\" * .* 2> /dev/null"))
        (save-current-buffer
          (set-buffer "*grep*")
          (rename-buffer l-result-buffer-name t))
        (eide-menu-build-files-lists))
      (eide-search-view-output-buffer l-result-buffer-name))
    (eide-windows-select-source-window t)))

(defun eide-search-grep-local-without-prompt ()
  "Grep word at cursor position, in current directory."
  (interactive)
  (if eide-search-grep-enabled-flag
    (let ((l-string (find-tag-default)))
      (if l-string
        (eide-search-grep-local l-string)))))

(defun eide-search-grep-local-with-prompt ()
  "Grep a string in current directory (prompt for it)."
  (interactive)
  (if eide-search-grep-enabled-flag
    (let ((l-string (read-string "Grep (in current directory): ")))
      (if (string-equal l-string "")
        (message "Cannot grep empty string...")
        (eide-search-grep-local l-string)))))

(defun eide-search-grep-global (p-string)
  "Grep a string in the whole project.
Argument:
- p-string: string."
  ;; On Emacs 22 GTK: it is necessary to select "source" window, otherwise
  ;; current output buffer will be reused if "output" window is selected.
  (eide-windows-select-source-window t)
  (let ((l-result-buffer-name (concat "*grep (global)*: " p-string))
        (l-do-it-flag t))
    (if (get-buffer l-result-buffer-name)
      (if (eide-popup-question-yes-or-no-p "This string has already been searched... Search again (or use available search result)?")
        ;; Delete existing grep buffer
        (kill-buffer l-result-buffer-name)
        (setq l-do-it-flag nil)))
    (if l-do-it-flag
      (progn
        ;; Temporarily change current directory, so that grep results are relative to root directory
        (let ((default-directory eide-root-directory))
          ;; grep options: r (recursive), I (no binary), n (show line number), e (pattern may start with '-')
          ;; 2> /dev/null is used to hide warnings about missing files
          ;; 'cd' is used first, in case shell init changes current directory
          (grep-find (concat "echo ; cd " eide-root-directory " ; grep -rIn " eide-search-grep-exclude-options " -e \"" p-string "\" . 2> /dev/null")))
        (save-current-buffer
          (set-buffer "*grep*")
          (rename-buffer l-result-buffer-name t))
        (eide-menu-build-files-lists))
      (eide-search-view-output-buffer l-result-buffer-name))
    (eide-windows-select-source-window t)))

(defun eide-search-grep-global-without-prompt ()
  "Grep word at cursor position, in the whole project."
  (interactive)
  (if eide-search-grep-enabled-flag
    (let ((l-string (find-tag-default)))
      (if l-string
        (eide-search-grep-global l-string)))))

(defun eide-search-grep-global-with-prompt ()
  "Grep a string in the whole project (prompt for it)."
  (interactive)
  (if eide-search-grep-enabled-flag
    (let ((l-string (read-string "Grep (in whole project): ")))
      (if (string-equal l-string "")
        (message "Cannot grep empty string...")
        (eide-search-grep-global l-string)))))

(defun eide-search-grep-go-to-previous ()
  "Go to previous grep match (or compilation error)."
  (interactive)
  (if eide-search-grep-enabled-flag
    (progn
      (previous-error)
      (if (not eide-windows-ide-windows-visible-flag)
        ;; Close grep window (appears automatically with previous-error)
        (delete-other-windows))
      (recenter)
      ;; Update menu because a new file may have been opened
      (eide-menu-update nil)
      (eide-windows-select-source-window nil))))

(defun eide-search-grep-go-to-next ()
  "Go to next grep match (or compilation error)."
  (interactive)
  (if eide-search-grep-enabled-flag
    (progn
      (next-error)
      (if (not eide-windows-ide-windows-visible-flag)
        ;; Close grep window (appears automatically with next-error)
        (delete-other-windows))
      (recenter)
      ;; Update menu because a new file may have been opened
      (eide-menu-update nil)
      (eide-windows-select-source-window nil))))

(defun eide-search-read-man (p-args)
  "Read man page.
Argument:
- p-args: man arguments (including section number or \"-a\")."
  (eide-windows-select-source-window t)
  (man p-args))

(defun eide-search-view-output-buffer (p-result-buffer-name)
  "Display a result buffer.
Argument:
- p-result-buffer-name: buffer name."
  (eide-windows-select-output-window)
  (switch-to-buffer p-result-buffer-name))

(defun eide-search-close-grep-buffer (p-grep-buffer-name)
  "Close a grep result buffer.
Argument:
- p-grep-buffer-name: buffer name."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (kill-buffer p-grep-buffer-name)
    (setq eide-menu-grep-results-list (remove p-grep-buffer-name eide-menu-grep-results-list))

    (if (string-equal p-grep-buffer-name l-buffer)
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-grep-results-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-cscope-results-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (progn
                (setq l-buffer (car eide-menu-man-pages-list))
                (if l-buffer
                  (switch-to-buffer l-buffer)
                  (switch-to-buffer "*results*"))))))))))

(defun eide-search-close-all-grep-buffers ()
  "Close all grep result buffers."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (dolist (l-grep-buffer-name eide-menu-grep-results-list)
      (kill-buffer l-grep-buffer-name))
    (setq eide-menu-grep-results-list nil)

    (if (not (string-equal (buffer-name) l-buffer))
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-cscope-results-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-man-pages-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (switch-to-buffer "*results*"))))))))

(defun eide-search-close-cscope-buffer (p-cscope-buffer-name)
  "Close a cscope result buffer.
Argument:
- p-cscope-buffer-name: buffer name."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (kill-buffer p-cscope-buffer-name)
    (setq eide-menu-cscope-results-list (remove p-cscope-buffer-name eide-menu-cscope-results-list))

    (if (string-equal p-cscope-buffer-name l-buffer)
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-cscope-results-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-grep-results-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (progn
                (setq l-buffer (car eide-menu-man-pages-list))
                (if l-buffer
                  (switch-to-buffer l-buffer)
                  (switch-to-buffer "*results*"))))))))))

(defun eide-search-close-all-cscope-buffers ()
  "Close all cscope result buffers."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (dolist (l-cscope-buffer-name eide-menu-cscope-results-list)
      (kill-buffer l-cscope-buffer-name))
    (setq eide-menu-cscope-results-list nil)

    (if (not (string-equal (buffer-name) l-buffer))
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-grep-results-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-man-pages-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (switch-to-buffer "*results*"))))))))

(defun eide-search-close-man-buffer (p-man-buffer-name)
  "Close a man page buffer.
Argument:
- p-man-buffer-name: buffer name."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (kill-buffer p-man-buffer-name)
    (setq eide-menu-man-pages-list (remove p-man-buffer-name eide-menu-man-pages-list))

    (if (string-equal p-man-buffer-name l-buffer)
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-man-pages-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-grep-results-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (progn
                (setq l-buffer (car eide-menu-cscope-results-list))
                (if l-buffer
                  (switch-to-buffer l-buffer)
                  (switch-to-buffer "*results*"))))))))))

(defun eide-search-close-all-man-buffers ()
  "Close all man page buffers."
  (eide-windows-select-output-window)
  (let ((l-buffer (buffer-name)))
    (dolist (l-man-buffer-name eide-menu-man-pages-list)
      (kill-buffer l-man-buffer-name))
    (setq eide-menu-man-pages-list nil)

    (if (not (string-equal (buffer-name) l-buffer))
      ;; Current result buffer was closed: display another one
      (progn
        (setq l-buffer (car eide-menu-grep-results-list))
        (if l-buffer
          (switch-to-buffer l-buffer)
          (progn
            (setq l-buffer (car eide-menu-cscope-results-list))
            (if l-buffer
              (switch-to-buffer l-buffer)
              (switch-to-buffer "*results*"))))))))

;;; eide-search.el ends here
