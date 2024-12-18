;;;; mongodb.lisp

(defpackage #:microblog.datastore.mongodb
  (:use #:cl #:iter #:mongo.sugar #:microblog.policy.datastore)
  (:export #:microblog-mongo-datastore #:make-query))

(in-package #:microblog.datastore.mongodb)

(defgeneric make-query (datastore &rest args))

(defclass microblog-mongo-datastore ()
  ((dbspec :initarg :dbspec :initform '(:name "blog") :reader dbspec)))

(defmethod make-query ((datastore microblog-mongo-datastore) &rest args)
  (apply #'son args))

(defmacro with-mongodb ((db datastore) &body body)
  (alexandria:with-unique-names (dbspec client)
    `(let ((,dbspec (dbspec ,datastore)))
       (mongo:with-client (,client (mongo:create-mongo-client :usocket
                                                              :server (make-instance 'mongo:server-config
                                                                                     :hostname (getf ,dbspec :hostname)
                                                                                     :port (getf ,dbspec :port))))
         (let ((,db (make-instance 'mongo:database
                                   :mongo-client ,client
                                   :name (getf ,dbspec :name))))
           ;; :username (getf ,dbspec :username)
           ;; :password (getf ,dbspec :password)
           ,@body)))))

(defmacro with-posts-collection ((name datastore) &body body)
  (alexandria:with-unique-names (db-symbol)
    `(with-mongodb (,db-symbol ,datastore)
       (let ((,name (mongo:collection ,db-symbol "posts")))
         ,@body))))
        
(defun calc-sha1-sum (val)
  "Calc sha1 sum of the val (string)"
  (ironclad:byte-array-to-hex-string
   (ironclad:digest-sequence :sha1
                             (babel:string-to-octets val :encoding :utf-8))))

(defun list-fields-query (fields)
  (let ((fields-query nil))
    (when fields
      (setf fields-query (make-hash-table :test 'equal))
      (iter (for field in fields)
            (setf (gethash field fields-query) 1)))
    fields-query))

(defmethod datastore-list-recent-posts ((datastore microblog-mongo-datastore) skip limit &key tag fields)
  (with-posts-collection (posts datastore)
    (mongo:find-list posts
                     :query (son "$query" (if tag
                                              (make-query datastore "tags" tag)
                                              (make-query datastore))
                                 "$orderby" (son "published" -1))
                     :limit limit
                     :skip skip
                     :fields (list-fields-query fields))))

(defmethod datastore-count-posts ((datastore microblog-mongo-datastore) &optional tag)
  (with-posts-collection (posts datastore)
    (mongo:$count posts
                  (and tag (make-query datastore "tags" tag)))))

(defmethod datastore-find-single-post ((datastore microblog-mongo-datastore) year month day urlname)
  (let* ((min (local-time:encode-timestamp 0 0 0 0 day month year))
         (max (local-time:adjust-timestamp min (offset :day 1))))
    (with-posts-collection (posts datastore)
      (mongo:find-one posts
                      :query (make-query datastore
                                         "published" (son "$gte" min "$lt" max)
                                         "urlname" urlname)))))

(defmethod datastore-get-single-post ((datastore microblog-mongo-datastore) id &key fields)
  (with-posts-collection (posts datastore)
    (mongo:find-one posts
                    :query (make-query datastore "_id" id)
                    :selector (list-fields-query fields))))
  

(defmethod datastore-list-archive-posts ((datastore microblog-mongo-datastore) min max &optional fields)
  (let ((fields-query (list-fields-query fields)))
    (with-posts-collection (posts datastore)
      (mongo:find-list posts
                       :query (son "$query" (make-query datastore
                                                        "published" (son "$gte" min "$lt" max))
                                   "$orderby" (son "published" -1))
                       :fields fields-query))))

(defmethod datastore-all-tags ((datastore microblog-mongo-datastore))
  (with-posts-collection (posts datastore)
    (mongo:$distinct posts "tags")))

(defmethod datastore-insert-post ((datastore microblog-mongo-datastore) title tags content &key markup published updated)
  (let* ((now (local-time:now))
         (id (calc-sha1-sum (format nil "~A~A" title published)))
         (post (make-query datastore
                           "_id" id
                           "title" title
                           "urlname" (microblog:title-to-urlname title)
                           "published" now
                           "updated" now
                           "content" content
                           "tags" (coerce tags 'vector))))
    (when markup
      (setf (gethash "markup" post)
            markup))
    (when published
      (setf (gethash "published" post)
            published))
    (when updated
      (setf (gethash "published" post)
            updated))
    (with-posts-collection (posts datastore)
      (mongo:insert-op posts post))
    id))

(defmethod datastore-update-post ((datastore microblog-mongo-datastore) id title tags content &key markup)
  (with-posts-collection (posts datastore)
    (let ((post (mongo:find-one posts :query (make-query datastore "_id" id))))
      (setf (gethash "title" post) title
            (gethash "urlname" post) (microblog:title-to-urlname title)
            (gethash "content" post) content
            (gethash "tags" post) (coerce tags 'vector)
            (gethash "updated" post) (local-time:now)
            (gethash "markup" post) markup)
      (mongo:update-op posts (son "_id" id) post))))

(defmethod datastore-set-admin ((datastore microblog-mongo-datastore) admin-name admin-password)
  (with-mongodb (db datastore)
    (mongo:update-op (mongo:collection db "meta")
                     (make-query datastore "type" "admin")
                     (make-query datastore
                                 "type" "admin"
                                 "info" (son "name" admin-name
                                             "password" (calc-sha1-sum admin-password)))
                     :upsert t)))

(defmethod datastore-check-admin ((datastore microblog-mongo-datastore) admin-name admin-password)
  (with-mongodb (db datastore)
    (let ((info (mongo:find-one (mongo:collection db "meta") :query (make-query datastore "type" "admin"))))
      (when info
        (let ((admin (gethash "info" info)))
          (and (string= (gethash "name" admin) admin-name)
               (string= (gethash "password" admin) (calc-sha1-sum admin-password))))))))

;;;  Helpers

(defun import-posts-from-datastore (origin target)
  (with-posts-collection (origin-posts origin)
    (with-posts-collection (target-posts target)
      (mongo:with-cursor (origin-post-cursor origin-posts (son))
        (mongo:docursor (post origin-post-cursor)
          (mongo:insert-op target-posts post))))))
        
(defun remove-all-posts (datastore)
  (with-posts-collection (posts datastore)
    (mongo:delete-op posts (son))))

(defun remove-last-post (datastore)
  (with-posts-collection (posts datastore)
    (mongo:delete-op posts 
                     (car (datastore-list-recent-posts datastore 0 1 :fields "_id"))
                     :single-remove t)))

;;; upgrade

(defun upgrade-datastore (datastore)
  (flet ((upgrade-post (post)
           (when (gethash "content-rst" post)
             (setf (gethash "markup" post)
                   (gethash "content-rst" post))
             (remhash "content-rst" post))
           (setf (gethash "urlname" post)
                 (microblog:title-to-urlname (gethash "title" post)))))
    (with-posts-collection (posts datastore)
      (mongo:with-cursor (cursor posts (son))
        (mongo:docursor (post cursor)
          (upgrade-post post)
          (mongo:update-op posts (son "_id" (gethash "_id" post)) post))))))


