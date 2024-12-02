;;;; microblog.asd

(require :asdf)

(asdf:operate 'asdf:load-op '#:closure-template)

(defsystem #:microblog
  :defsystem-depends-on (#:closure-template)
  :depends-on (restas
               local-time 
               #:closure-template)
  :pathname "core/"
  :serial t
  :components ((:file "defmodules")
               (#:closure-template "feed")
               (:file "microblog")
               (:file "public")
               (:file "admin")
               (:file "static")))
