;;; helm-qiita.el --- Qiita with helm interface -*- lexical-binding: t; -*-

;; Copyright (C) 2016 by Takashi Masuda

;; Author: Takashi Masuda <masutaka.net@gmail.com>
;; URL: https://github.com/masutaka/emacs-helm-qiita
;; Version: 0.0.1
;; Package-Requires: ((helm "20160401.1145"))

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <http://www.gnu.org/licenses/>.

;;; Commentary:
;; helm-qiita.el provides a helm interface to Qiita.

;;; Code:

(require 'helm)
(require 'json)

(defgroup helm-qiita nil
  "Qiita with helm interface"
  :prefix "helm-qiita:"
  :group 'helm)

(defcustom helm-qiita:username nil
  "A username of your Qiita account."
  :type '(choice (const nil)
		 string)
  :group 'helm-qiita)

(defcustom helm-qiita:organization nil
  "A name of your Qiita organization."
  :type '(choice (const nil)
		 string)
  :group 'helm-qiita)

(defcustom helm-qiita:access-token nil
  "Your Qiita access token.
You can create in https://qiita.com/settings/applications"
  :type '(choice (const nil)
		 string)
  :group 'helm-qiita)

(defcustom helm-qiita:file
  (expand-file-name "helm-qiita" user-emacs-directory)
  "A cache file of your Qiita Stocks"
  :type '(choice (const nil)
		 string)
  :group 'helm-qiita)

(defcustom helm-qiita:candidate-number-limit 10000
  "Candidate number limit."
  :type 'integer
  :group 'helm-qiita)

(defcustom helm-qiita:interval (* 1 60 60)
  "Number of seconds to call `helm-qiita:http-request'."
  :type 'integer
  :group 'helm-qiita)

(defvar helm-qiita:url nil
  "Cache a result of `helm-qiita:get-url'.
DO NOT SET VALUE MANUALLY.")

(defvar helm-qiita:curl-program nil
  "Cache a result of `helm-qiita:find-curl-program'.
DO NOT SET VALUE MANUALLY.")

(defvar helm-qiita:http-buffer-name " *helm-qiita-http*"
  "HTTP Working buffer name of `helm-qiita:http-request'.")

(defvar helm-qiita:work-buffer-name " *helm-qiita-work*"
  "Working buffer name of `helm-qiita:http-request'.")

(defvar helm-qiita:full-frame helm-full-frame)

(defvar helm-qiita:timer nil
  "Timer object for Qiita caching will be stored here.
DO NOT SET VALUE MANUALLY.")

(defvar helm-qiita:debug-mode nil)
(defvar helm-qiita:debug-start-time nil)

(defun helm-qiita:load ()
  "Load `helm-qiita:file'."
  (with-current-buffer (helm-candidate-buffer 'global)
    (let ((coding-system-for-read 'utf-8))
      (insert-file-contents helm-qiita:file))))

(defvar helm-qiita:action
  '(("Browse URL" . helm-qiita:browse-url)
    ("Show URL" . helm-qiita:show-url)))

(defun helm-qiita:browse-url (candidate)
  "Action for Browse URL.
Argument CANDIDATE a line string of a stock."
  (string-match "\\[href:\\(.+\\)\\]" candidate)
  (browse-url (match-string 1 candidate)))

(defun helm-qiita:show-url (candidate)
  "Action for Show URL.
Argument CANDIDATE a line string of a stock."
  (string-match "\\[href:\\(.+\\)\\]" candidate)
  (message (match-string 1 candidate)))

(defvar helm-qiita:source
  (helm-build-in-buffer-source "Qiita Stocks"
    :init 'helm-qiita:load
    :action 'helm-qiita:action
    :candidate-number-limit helm-qiita:candidate-number-limit
    :multiline t
    :migemo t)
  "Helm source for Qiita.")

;;;###autoload
(defun helm-qiita ()
  "Search Qiita Stocks using `helm'."
  (interactive)
  (let ((helm-full-frame helm-qiita:full-frame))
    (unless (file-exists-p helm-qiita:file)
      (error (format "%s not found" helm-qiita:file)))
    (helm :sources helm-qiita:source
	  :prompt "Find Qiita Stocks: ")))

(defun helm-qiita:find-curl-program ()
  "Return an appropriate `curl' program pathname or error if not found."
  (or
   (executable-find "curl")
   (error "Cannot find `curl' helm-qiita.el requires")))

(defun helm-qiita:get-url ()
  "Return Qiita URL or error if `helm-qiita:username' is nil."
  (unless helm-qiita:username
    (error "Variable `helm-qiita:username' is nil"))
  (format "https://%s/api/v2/users/%s/stocks?page=1&per_page=20"
	  (if (stringp helm-qiita:organization)
	      (concat helm-qiita:organization ".qiita.com")
	    "qiita.com")
	  helm-qiita:username))

(defun helm-qiita:http-request (&optional url)
  "Make a new HTTP request for create `helm-qiita:file'."
  (let ((http-buffer-name helm-qiita:http-buffer-name)
	(work-buffer-name helm-qiita:work-buffer-name)
	(proc-name "helm-qiita")
	(curl-args `("--include" "-X" "GET" "--compressed"
		     "--header" ,(concat "Authorization: Bearer " helm-qiita:access-token)
		     ,(if url url helm-qiita:url)))
	proc)
    (unless (get-buffer-process http-buffer-name)
      (if (get-buffer http-buffer-name)
	  (kill-buffer http-buffer-name))
      (unless url ;; 1st page
	(if (get-buffer work-buffer-name)
	    (kill-buffer work-buffer-name))
	(get-buffer-create work-buffer-name))
      (helm-qiita:http-debug-start)
      (setq proc (apply 'start-process
			proc-name
			http-buffer-name
			helm-qiita:curl-program
			curl-args))
      (set-process-sentinel proc 'helm-qiita:http-request-sentinel))))

(defun helm-qiita:http-request-sentinel (process event)
  "Receive a response of `helm-qiita:http-request'.
Argument PROCESS is a http-request process.
Argument EVENT is a string describing the type of event."
  (let (response next-link stock)
    (with-current-buffer (get-buffer helm-qiita:http-buffer-name)
      (setq valid-response (helm-qiita:valid-http-responsep))
      (setq next-link (helm-qiita:next-link))
      (setq response (json-read-from-string
		      (buffer-substring-no-properties
		       (+ (helm-qiita:point-of-separator) 1) (point-max)))))
    (with-current-buffer (get-buffer helm-qiita:work-buffer-name)
      (goto-char (point-max))
      (dotimes (i (length response))
	(setq stock (aref response i))
	(insert (format "%s %s [href:%s]\n"
			(helm-qiita:stock-title stock)
			(helm-qiita:stock-format-tags stock)
			(helm-qiita:stock-url stock))))
      (helm-qiita:http-debug-end valid-response)
      (if next-link
	  (helm-qiita:http-request next-link)
	(write-region (point-min) (point-max) helm-qiita:file)))))

(defun helm-qiita:valid-http-responsep ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward
     (concat "^" (regexp-quote "HTTP/1.1 200 OK")) (point-at-eol) t)))

(defun helm-qiita:next-link ()
  (save-excursion
    (let ((field-body))
      (goto-char (point-min))
      (when (re-search-forward "^Link: " (helm-qiita:point-of-separator) t)
	(setq field-body (buffer-substring-no-properties (point) (point-at-eol)))
	(cond
	 ((string-match "^<\\(https://.*\\)>; rel=\"first\", <\\(https://.*\\)>; rel=\"prev\", <\\(https://.*\\)>; rel=\"next\"" field-body)
	  (match-string 3 field-body))
	 ((string-match "^<\\(https://.*\\)>; rel=\"first\", <\\(https://.*\\)>; rel=\"next\"" field-body)
	  (match-string 2 field-body)))))))

(defun helm-qiita:point-of-separator ()
  (save-excursion
    (goto-char (point-min))
    (re-search-forward "^?$" nil t)))

(defun helm-qiita:stock-title (stock)
  (cdr (assoc 'title stock)))

(defun helm-qiita:stock-url (stock)
  (cdr (assoc 'url stock)))

(defun helm-qiita:stock-format-tags (stock)
  (let ((result ""))
    (mapc
     (lambda (tag)
       (setq result (format "%s[%s]" result tag)))
     (helm-qiita:stock-tags stock))
    result))

(defun helm-qiita:stock-tags (stock)
  (let ((tags (cdr (assoc 'tags stock))) result)
    (dotimes (i (length tags))
      (add-to-list 'result (cdr (assoc 'name (aref tags i)))))
    (reverse result)))

(defun helm-qiita:http-debug-start ()
  (setq helm-qiita:debug-start-time (current-time)))

(defun helm-qiita:http-debug-end (result)
  (if helm-qiita:debug-mode
      (message (format "[Q] %s to create %s (%0.1fsec) at %s."
		       (if result "Success" "Failure")
		       helm-qiita:file
		       (time-to-seconds
			(time-subtract (current-time)
				       helm-qiita:debug-start-time))
		       (format-time-string "%Y-%m-%d %H:%M:%S" (current-time))))))

(defun helm-qiita:set-timer ()
  "Set timer."
  (setq helm-qiita:timer
	(run-at-time "0 sec"
		     helm-qiita:interval
		     #'helm-qiita:http-request)))

(defun helm-qiita:cancel-timer ()
  "Cancel timer."
  (when helm-qiita:timer
    (cancel-timer helm-qiita:timer)
    (setq helm-qiita:timer nil)))

;;;###autoload
(defun helm-qiita:initialize ()
  "Initialize `helm-qiita'."
  (setq helm-qiita:url
	(helm-qiita:get-url))
  (unless helm-qiita:access-token
    (error "Variable `helm-qiita:access-token' is nil"))
  (setq helm-qiita:curl-program
	(helm-qiita:find-curl-program))
  (helm-qiita:set-timer))

(provide 'helm-qiita)
