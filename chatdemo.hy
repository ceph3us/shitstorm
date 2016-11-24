(import
  [logging]
  [tornado.escape]
  [tornado.ioloop]
  [tornado.web]
  [os.path]
  [uuid])

(import
  [tornado.concurrent [Future]]
  [tornado [gen]]
  [tornado.options [define :as defoption options parse-command-line]])

(require [hy.contrib.anaphoric [*]])

; Define options for this appserver

(defoption "port"
  :default 8888
  :help "run on the given port"
  :type int)

(defoption "debug"
  :default False
  :help "run in debug mode")

(defclass MessageBuffer []
  [waiters (set)
    cache []
    cache-size 200]
  (defn wait-for-messages [self &optional [cursor None]]
    (let [result-future (Future)]
      (if cursor
        (let [check-mq (fn [queue count]
          (if-not (or (nil? queue) (empty? queue)) (logging.info "Message at top of queue is %s" (str (car queue))))
          (logging.info "Cursor is %s" (str cursor))
            (if
              (or (nil? queue) (empty? queue)) count
              (= (get (car queue) "id") cursor) count
              (check-mq (cdr queue) (+ count 1))))]
          (setv msgs (check-mq (list (reversed self.cache)) 0))
          (if
            (> msgs 0) (.set-result result-future (list (drop
                                                    (- (len self.cache) msgs)
                                                    self.cache)))
            (.add self.waiters result-future)))
        (.add self.waiters result-future))
      result-future))
  (defn cancel-wait [self future]
    (.remove self.waiters future)
    (.set-result future []))
  (defn new-messages [self messages]
    (logging.info "Sending new message to %r listeners" (len self.waiters))
    (ap-each self.waiters (.set-result it messages))
    (setv self.waiters (set))
    (.extend self.cache messages)))

(setv global-message-buffer (MessageBuffer))

(defclass MainHandler [tornado.web.RequestHandler] []
  (defn get [self] (.render self "index.html" :messages global-message-buffer.cache)))

(defclass MessageNewHandler [tornado.web.RequestHandler] []
  (defn post [self] (let [message {"id" (str (uuid.uuid4))
                                    "body" (.get-argument self "body")}]
    (assoc message "html" (tornado.escape.to-basestring
                              (.render-string self "message.html" :message message)))
    (if
      (.get-argument self "next" nil) (.redirect self (.get-argument self "next"))
      (.write self message))
    (.new-messages global-message-buffer (list [message])))))

(defclass MessageUpdatesHandler [tornado.web.RequestHandler] []
  (#@(gen.coroutine (defn post [self]
    (let [cursor (.get-argument self "cursor" nil)]
      (setv self.future (.wait-for-messages global-message-buffer :cursor cursor)))
    (let [messages (yield self.future)]
      (if
        (not (.closed self.request.connection.stream))
          (.write self {"messages" messages})))))
  (defn on-connection-close [self] (.cancel-wait global-message-buffer self.future))))

(defn make-app [] (tornado.web.Application
  [(, "/" MainHandler)
    (, "/a/message/new" MessageNewHandler)
    (, "/a/message/updates" MessageUpdatesHandler)]
  :cookie-secret "__TODO:_GENERATE_YOUR_OWN_RANDOM_VALUE_HERE__"
  :template-path (os.path.join (os.path.dirname __file__) "templates")
  :static-path (os.path.join (os.path.dirname __file__) "static")
  :xsrf-cookies True
  :debug options.debug))

(defmain [&rest args]
  (parse-command-line)
  (let [app (make-app)]
    (.listen app options.port))
  (-> (.current tornado.ioloop.IOLoop) (.start)))
