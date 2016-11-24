; Copyright 2009 Facebook
; Copyright 2016 Michael Holmes <ceph3us@users.github.com>
;
; Licensed under the Apache License, Version 2.0 (the "License"); you may
; not use this file except in compliance with the License. You may obtain
; a copy of the License at
;
;     http://www.apache.org/licenses/LICENSE-2.0
;
; Unless required by applicable law or agreed to in writing, software
; distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
; WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied. See the
; License for the specific language governing permissions and limitations
; under the License.
;
; SPDX-License-Identifier: Apache-2.0

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
  (defn wait-for-messages [self &optional [cursor nil]]
    ; Construct a Future to return to our caller. This allows
    ; wait-for-messages to be yielded from a coroutine even though
    ; it is not a coroutine itself. We will set the result of the
    ; Future when results are available.
    (let [result-future (Future)]
      (if cursor
        ; Definitely not optimal, but a more lispy tail recursion
        (let [check-mq (fn [queue count]
          (if-not (or (nil? queue) (empty? queue))
            (logging.debug "Message at top of queue is %s" (str (car queue))))
          (logging.debug "Cursor is %s" (str cursor))
            (if
              (or (nil? queue) (empty? queue)) count ; Dead queue... finish up
              (= (get (car queue) "id") cursor) count
              (check-mq (cdr queue) (+ count 1))))]
          (setv msgs (check-mq (list (reversed self.cache)) 0))
          (if
            (> msgs 0)
              ; Allow the Future to be yielded with the unsent messages
              (.set-result result-future (list (drop (- (len self.cache) msgs)
                                                  self.cache)))
              ; Add this Future to the list of waiting listeners if queue empty
              (.add self.waiters result-future)))
          ; Ditto if there was no cursor to indicate last read position
          (.add self.waiters result-future))
      result-future))
  (defn cancel-wait [self future]
    (.remove self.waiters future)
    (.set-result future []))
  (defn new-messages [self messages]
    (logging.info "Sending new message to %r listeners" (len self.waiters))
    ; Distribute the message queue to all long-polling clients
    (ap-each self.waiters (.set-result it messages))
    ; Empty the long poll Future queue
    (setv self.waiters (set))
    ; Append messages to the message history
    (.extend self.cache messages)))

; Making this a non-singleton is also left as an exercise for the reader!
(setv global-message-buffer (MessageBuffer))

(defclass MainHandler [tornado.web.RequestHandler] []
  (defn get [self]
    (.render self "index.html" :messages global-message-buffer.cache)))

(defclass MessageNewHandler [tornado.web.RequestHandler] []
  (defn post [self] (let [message {"id" (str (uuid.uuid4))
                                    "body" (.get-argument self "body")}]
    (assoc message "html"
      (tornado.escape.to-basestring
        (.render-string self "message.html" :message message)))
    (if
      (.get-argument self "next" nil)
        (.redirect self (.get-argument self "next"))
      (.write self message))
    (.new-messages global-message-buffer (list [message])))))

(defclass MessageUpdatesHandler [tornado.web.RequestHandler] []
  (#@(gen.coroutine (defn post [self]
    (let [cursor (.get-argument self "cursor" nil)]
      (setv self.future
        (.wait-for-messages global-message-buffer :cursor cursor)))
    (let [messages (yield self.future)]
      (if
        (not (.closed self.request.connection.stream))
          (.write self {"messages" messages})))))
  (defn on-connection-close [self]
    (.cancel-wait global-message-buffer self.future))))

;; TODO: Probably make some fancy macro that makes creating a new Tornado app
;;       instance with routes and options easier
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
