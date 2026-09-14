# Copyright (c) 2026 Calvin Rose & contributors
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to
# deal in the Software without restriction, including without limitation the
# rights to use, copy, modify, merge, publish, distribute, sublicense, and/or
# sell copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
#
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
# FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS
# IN THE SOFTWARE.

# Expand on ev testing with some extra network protocol testing.

(import ./helper :prefix "" :exit true)
(start-suite)

# Smoke
(assert true)

# Nothing in this suite exists in a build without JANET_NET, and an absent
# binding is a compile error rather than a runtime one. Janet compiles and runs
# a file one top-level form at a time, so leaving here keeps the rest of the
# suite from reaching the compiler at all.
(compwhen (not (dyn 'net/server))
  (end-suite)
  (os/exit 0))

# Raw socket testing
(def s (net/socket :datagram :ipv4))
(assert-no-error "multicast ipv4" (net/setsockopt s :ip-multicast-ttl 255))
#(def s6 (net/socket :datagram :ipv6))
#(assert-no-error "multicast ipv6" (net/setsockopt s6 :ipv6-multicast-hops 255))

# net/socket, and what an unbound one reports
(assert (= :core/stream (type (net/socket))) "net/socket defaults to a stream")
(assert (= ["0.0.0.0" 0] (net/localname (net/socket :datagram :ipv4)))
        "an unbound datagram socket has the wildcard address")
(assert-error "net/socket rejects an unknown type" (net/socket :tcp))
(assert-no-error "an unknown address family is not an error" (net/socket :stream :ipx))

# net/setsockopt's vocabulary
(assert-no-error "so-broadcast" (net/setsockopt s :so-broadcast true))
(assert-no-error "so-reuseaddr" (net/setsockopt s :so-reuseaddr true))
(assert-no-error "so-keepalive" (net/setsockopt s :so-keepalive false))
(assert-error "unknown socket option" (net/setsockopt s :nope 1))
(assert-error "so-broadcast wants a boolean" (net/setsockopt s :so-broadcast "yes"))
(assert-error "ip-multicast-ttl wants a number" (net/setsockopt s :ip-multicast-ttl :x))
(assert-error "ip-add-membership wants a string" (net/setsockopt s :ip-add-membership 1))

# net/address, and the shape of what it returns.
#
# `multi` is the fourth argument, so a three-argument call has not been given
# one and answers the single address it documents. Reading the fourth slot
# whenever three were given answers with whatever the caller's frame left
# behind, which is a wrong answer where `argv` is a pointer and an
# out-of-bounds index where it is a slice.
(assert (= :core/socket-address (type (net/address "127.0.0.1" 8123 :stream)))
        "three arguments answer one address")
(assert (= :core/socket-address (type (net/address "127.0.0.1" 8123)))
        "two arguments answer one address")
(def addr (net/address "127.0.0.1" 8123 :stream false))
(assert (= :core/socket-address (type addr)) "net/address returns an address")
(assert (= ["127.0.0.1" 8123] (net/address-unpack addr)) "an address unpacks")
(assert (= ["127.0.0.1" 8123] (net/address-unpack (net/address "127.0.0.1" "8123")))
        "the port may be a string")
(def multi (net/address "127.0.0.1" 8123 :stream true))
(assert (indexed? multi) "multi returns an array")
(assert (all |(= ["127.0.0.1" 8123] (net/address-unpack $)) multi)
        "every address multi returns unpacks")
(assert-error "net/address rejects an unknown type"
              (net/address "127.0.0.1" 8123 :tcp false))

# A connection handler is entered with the connection and nothing else, so its
# arity is checked where the handler is first seen -- before any connection --
# rather than at the first one, where the fiber constructor's refusal reaches
# no caller. `net/server` spawns the loop asynchronously, so `net/accept-loop`
# is where a suite can ask.
(def arity-listener (net/listen "127.0.0.1" "8127"))
(defer (:close arity-listener)
  (assert-error-value "a handler taking no arguments is refused"
                      "handler function must take at least 1 argument"
                      (net/accept-loop arity-listener (fn [] nil)))
  (assert-error-value "a handler taking two arguments is refused"
                      "handler function must take at most 1 argument"
                      (net/accept-loop arity-listener (fn [_a _b] nil))))

# A failed connect closes the socket through the stream that owns it, so the
# descriptor number is not left dead for the next thing that opens one.
(def probe-path "janet-suite-net-probe")
(defer (os/rm probe-path)
  (assert-error "connect to a socket that is not there"
                (net/connect :unix "/tmp/janet-suite-net-no-such-socket"))
  (with [f (file/open probe-path :w)]
    (file/write f "hello")
    (gccollect)
    (assert-no-error "the next descriptor still works" (file/flush f)))
  (assert (= "hello" (string (slurp probe-path)))
          "a failed connect does not close the next descriptor"))
(assert-error "net/address rejects an unresolvable host"
              (net/address "no-such-host.invalid" 8123))

# net/listen, and the stream it hands back
(def server (net/listen "127.0.0.1" 0))
(def [server-host server-port] (net/localname server))
(assert (= "127.0.0.1" server-host) "a listener reports the host it bound")
(assert (and (int? server-port) (pos? server-port))
        "a listener reports the port the kernel picked")
(assert-error "a listener has no peer" (net/peername server))
(assert-error "a listener is not readable" (net/read server 1))
(assert-error "a listener is not writable" (net/write server "x"))
(assert-error "a listener is not a datagram socket" (net/recv-from server 1 @""))
(assert-error "net/shutdown rejects an unknown mode" (net/shutdown server :both))

# The method table, in the order net.c registers it. `next` walks the table, so
# this sees the rows in order rather than only their membership.
(assert (deep= @[:chunk :close :read :write :flush :accept :accept-loop
                 :send-to :recv-from :evread :evchunk :evwrite :shutdown
                 :setsockopt]
               (seq [k :keys server] k))
        "a socket stream's methods, in order")

# net/accept-loop checks its handler before it suspends
(assert-error "accept-loop needs a handler that takes the connection"
              (net/accept-loop server (fn [] nil)))

# A closed stream is refused, and the two name readers say so themselves rather
# than through janet_stream_flags
(:close server)
(assert-error "net/localname on a closed stream" (net/localname server))
(assert-error "net/peername on a closed stream" (net/peername server))
(assert-error "net/shutdown on a closed stream" (net/shutdown server))
(assert-error "net/accept on a closed stream" (net/accept server))

# A datagram round trip, which is the one net/ path suite-ev.janet never takes
(def receiver (net/listen "127.0.0.1" 0 :datagram))
(def [_ udp-port] (net/localname receiver))
(def sender (net/socket :datagram :ipv4))
(def to (net/address "127.0.0.1" udp-port :datagram false))
(net/send-to sender to "ping")
(def inbuf @"")
(def from (net/recv-from receiver 64 inbuf))
(assert (= "ping" (string inbuf)) "a datagram arrives")
(assert (= :core/socket-address (type from)) "recv-from reports the sender")
(assert (= "127.0.0.1" (first (net/address-unpack from)))
        "and the sender is where it was sent from")
(net/send-to receiver from "pong")
(def backbuf @"")
(net/recv-from sender 64 backbuf)
(assert (= "pong" (string backbuf)) "and the reply comes back")
(:close receiver)
(:close sender)

# A unix domain socket, whose address is a one-element tuple
(compwhen (not= :windows (os/which))
  # A fixed name rather than one with the pid in it: `os/getpid` does not
  # exist in a `-Dprocesses=false` build, and a binding that is absent is a
  # compile error rather than a runtime one.
  (def uds "/tmp/janet-suite-net.sock")
  (protect (os/rm uds))
  (def uds-server (net/listen :unix uds))
  (assert (= [uds] (net/localname uds-server)) "a unix listener names its path")
  (assert (= [uds] (net/address-unpack (net/address :unix uds)))
          "and net/address agrees with it")
  (:close uds-server)
  (protect (os/rm uds))
  # A path longer than sun_path is truncated rather than rejected.
  (def long-path (string "/tmp/" (string/repeat "a" 200)))
  (def shortened (first (net/address-unpack (net/address :unix long-path))))
  (assert (< (length shortened) (length long-path)) "a long unix path is truncated")
  (assert (string/has-prefix? "/tmp/aaaa" shortened) "and keeps its prefix"))

# A failed connect raises rather than returning, and says what failed
(assert-error "connecting to a closed port raises" (net/connect "127.0.0.1" 1))
(compwhen (not= :windows (os/which))
  (assert-error "bindhost is not supported for unix domain sockets"
                (net/connect :unix "/tmp/a.sock" :stream "127.0.0.1" 0)))

# macOS's getaddrinfo reads an empty host as no host, so the passive flag
# decides between the loopback address, for an address to reach, and the
# wildcard, for one to listen on.
(compwhen (= :macos (os/which))
  (assert (has-value? ["::1" "127.0.0.1"] (first (net/address-unpack (net/address "" 4242))))
          "an empty host to reach is the loopback address")
  (with [wild (net/listen "" 0)]
    (def [wild-host wild-port] (net/localname wild))
    (assert (has-value? ["::" "0.0.0.0"] wild-host)
            "an empty host to listen on is the wildcard")
    (with [c (net/connect "" wild-port)]
      (assert (= ["::1" wild-port] (net/peername c))
              "an empty host to connect to is the loopback address"))))

# Only Linux reads a leading @ as an abstract address. Elsewhere it is a path
# like any other, and the listener makes a socket file there.
(compwhen (and (not= :windows (os/which)) (not= :linux (os/which)))
  (def at-path "@janet-suite-net-at")
  (protect (os/rm at-path))
  (def at-server (protect (net/listen :unix at-path)))
  (assert (first at-server) "a leading @ is bound as a path")
  (assert (= :socket (os/stat at-path :mode)) "and the path is a socket")
  (when (first at-server) (:close (at-server 1)))
  (protect (os/rm at-path)))

# A connection that is already waiting when net/accept is called is taken at
# once. The loop runs in between, so the readiness the listener reported for
# it has been and gone.
(with [early (net/listen "127.0.0.1" 0)]
  (with [c (net/connect "127.0.0.1" ((net/localname early) 1))]
    (ev/sleep 0.05)
    (def taken (protect (net/accept early 1)))
    (assert (first taken) "a waiting connection is accepted at once")
    (when (first taken) (:close (taken 1)))))

# A connected pair for the paths a connection takes once it is made
(def conn-server (net/listen "127.0.0.1" 0))
(def [_ conn-port] (net/localname conn-server))
(def client (net/connect "127.0.0.1" conn-port))
(def peer (net/accept conn-server 2))

# A timeout is honoured where it is given. The deadline around each call is
# longer than the call's timeout, so a timeout that was never registered shows
# as the deadline's message rather than as a hang.
(defn timed-out [thunk] (in (protect (ev/with-deadline 2 (thunk))) 1))
(assert (= "timeout" (timed-out |(net/chunk client 4 @"" 0.05)))
        "net/chunk times out")
(assert (= "timeout" (timed-out |(net/read client :all @"" 0.05)))
        "net/read of :all times out")
(with [quiet (net/listen "127.0.0.1" 0 :datagram)]
  (assert (= "timeout" (timed-out |(net/recv-from quiet 8 @"" 0.05)))
          "net/recv-from times out"))

# net/chunk collects its whole count, and net/read of :all reads to the end of
# the stream, across writes that arrive apart.
(ev/spawn (net/write peer "abc") (ev/sleep 0.05) (net/write peer "def"))
(assert (= "abcdef" (string (net/chunk client 6))) "net/chunk waits for every byte")
(ev/spawn (net/write peer "ab") (ev/sleep 0.05) (net/write peer "cd") (:close peer))
(assert (= "abcd" (string (net/read client :all))) "net/read of :all reads to the end")

# A connection that is not a datagram socket refuses the datagram calls.
(assert (= "bad stream, expected datagram socket"
           (in (protect (net/recv-from client 1 @"" 0.05)) 1))
        "net/recv-from on a stream connection is refused")

# net/shutdown hands back the stream it shut
(assert (= client (net/shutdown client :w)) "net/shutdown returns the stream")
(:close client)

# A write that has to wait, because the peer never reads, times out too, for
# bytes and for a buffer.
(with [writer (net/connect "127.0.0.1" conn-port)]
  (def flood (string/repeat "x" (* 32 1024 1024)))
  (assert (= "timeout" (timed-out |(net/write writer flood 0.1)))
          "net/write of bytes times out")
  (assert (= "timeout" (timed-out |(net/write writer (buffer flood) 0.1)))
          "net/write of a buffer times out"))

# A connection binds its bindhost, and one that cannot be bound is refused.
(with [bound (net/connect "127.0.0.1" conn-port :stream "127.0.0.1" 0)]
  (assert (= "127.0.0.1" (first (net/localname bound))) "a connection binds its bindhost"))
(assert (string/has-prefix? "could not bind outgoing address"
                            (in (protect (net/connect "127.0.0.1" conn-port :stream "192.0.2.1" 0)) 1))
        "a bindhost that is not local is refused")
(:close conn-server)

# A buffer given to net/send-to is sent as its bytes.
(with [dgram-in (net/listen "127.0.0.1" 0 :datagram)]
  (def dgram-to (net/address "127.0.0.1" ((net/localname dgram-in) 1) :datagram))
  (with [dgram-out (net/socket :datagram :ipv4)]
    (net/send-to dgram-out dgram-to @"buffered")
    (def got @"")
    (protect (net/recv-from dgram-in 64 got 1))
    (assert (= "buffered" (string got)) "a buffer is sent as its bytes")
    (net/send-to dgram-out dgram-to "bytes")
    (def got-bytes @"")
    (protect (net/recv-from dgram-in 64 got-bytes 1))
    (assert (= "bytes" (string got-bytes)) "a string is sent as its bytes")))

# Group membership, and the IPv6 hop limit, which takes an int as the IPv4
# multicast TTL does on this platform.
(assert-no-error "ip-add-membership" (net/setsockopt s :ip-add-membership "224.0.0.251"))
(assert-no-error "ip-drop-membership" (net/setsockopt s :ip-drop-membership "224.0.0.251"))
(def s6 (protect (net/socket :datagram :ipv6)))
(when (first s6)
  (assert-no-error "ipv6-multicast-hops" (net/setsockopt (s6 1) :ipv6-multicast-hops 5)))

# IPv6 group membership, on a socket bound to the IPv6 loopback address. The
# group is a global one: a link-local group is joined on the interface the
# kernel picks for interface 0, and the same interface 0 does not name it to
# leave.
#
# A join on interface 0 fails with EADDRNOTAVAIL where no multicast-capable
# interface has a route for the group, which is the case on GitHub's macOS
# runners, and `net/setsockopt` names no other interface. That error skips both
# assertions and any other fails the join. The raised error is the `strerror`
# text alone: macOS and glibc spell EADDRNOTAVAIL "Can't assign requested address"
# and "Cannot assign requested address", musl and wasi-libc "Address not
# available".
(defn- no-multicast-route? [err]
  (def message (string err))
  (truthy? (or (string/find "assign requested address" message)
               (string/find "Address not available" message))))

(def lo6 (protect (net/listen "::1" 0 :datagram)))
(if (first lo6)
  (with [member (lo6 1)]
    (def [joined err] (protect (net/setsockopt member :ipv6-join-group "ff0e::1")))
    (when (and (not joined) (no-multicast-route? err))
      (eprint "skipped IPv6 membership: " err)
      (skip-asserts 2))
    (assert joined (if joined "ipv6-join-group" (string "ipv6-join-group: " err)))
    (assert-no-error "ipv6-leave-group" (net/setsockopt member :ipv6-leave-group "ff0e::1")))
  # `skip-asserts` marks the next two assertions to run as skipped rather
  # than counting two, so the two run here to be marked. Without them the
  # skip would fall on the next two assertions in the file.
  (do
    (eprint "skipped IPv6 membership: there is no IPv6 loopback address to bind")
    (skip-asserts 2)
    (assert false "ipv6-join-group")
    (assert false "ipv6-leave-group")))

# Two listeners may share a port, because a listener asks for SO_REUSEPORT
# where the platform has it.
(compwhen (not= :windows (os/which))
  (with [first-listener (net/listen "127.0.0.1" 0)]
    (def shared-port ((net/localname first-listener) 1))
    (def second-listener (protect (net/listen "127.0.0.1" shared-port)))
    (assert (first second-listener) "a second listener shares the port")
    (when (first second-listener) (:close (second-listener 1)))))

# Sockets are closed on exec: a listener, a connection and the socket the
# listener accepted. The child writes its count to a file rather than a pipe,
# a child that overruns is killed with a signal it cannot ignore, and the
# streams the process keeps for the files it was given are closed before the
# next count.
(compwhen (and (dyn 'os/spawn) (not= :windows (os/which)))
  (when (os/stat "/dev/fd")
    (def count-path "/tmp/janet-suite-net-fds")
    (defn fds-in-child []
      (with [out (file/open count-path :w)]
        (with [null (file/open "/dev/null" :w)]
          (def p (os/spawn [(dyn *executable*) "-e" `(print (length (os/dir "/dev/fd")))`]
                           :p {:out out :err null}))
          (unless (first (protect (ev/with-deadline 5 (os/proc-wait p))))
            (os/proc-kill p false :kill))
          (:close (p :out))
          (:close (p :err))))
      (scan-number (string/trim (string (slurp count-path)))))
    (defer (protect (os/rm count-path))
      (def before (fds-in-child))
      (with [listener (net/listen "127.0.0.1" 0)]
        (with [connection (net/connect "127.0.0.1" ((net/localname listener) 1))]
          (with [accepted (net/accept listener 2)]
            (assert (= before (fds-in-child)) "sockets are closed on exec")))))))

# net/accept-loop takes every connection that is waiting, not one for each
# readiness the listener reports: three clients that connect in one turn of
# the loop are all answered.
(with [echo (net/server "127.0.0.1" 0 (fn [c] (defer (:close c) (:write c (:read c 1)))))]
  (def [_ echo-port] (net/localname echo))
  (def replies (ev/chan 3))
  (repeat 3
    (ev/spawn
      (with [c (net/connect "127.0.0.1" echo-port)]
        (:write c "x")
        (ev/give replies (string (:read c 1 nil 1))))))
  (def answered (protect (ev/with-deadline 2 (seq [_ :range [0 3]] (ev/take replies)))))
  (assert (deep= [true @["x" "x" "x"]] answered)
          "net/accept-loop answers connections that arrive together"))

(end-suite)
