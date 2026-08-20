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
# `multi` is passed explicitly everywhere below, including where it is false.
# `net/address` reads its fourth argument whenever it was given three, which
# `port/FOUND.md` records; a suite that relied on the three-argument form would
# be asserting whatever the fiber stack happened to hold.
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

(end-suite)
