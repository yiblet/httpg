(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client, its
   Do entry point with redirect following, and the Get/Post/Head convenience
   verbs. *)

type check_redirect = Request.t list -> (unit, string) result
(** A redirect policy (Go's [CheckRedirect]): given the requests made so far
    ([via], most recent last), [Ok ()] permits the next hop and [Error msg]
    aborts. *)

val default_check_redirect : check_redirect
(** Go's [defaultCheckRedirect]: abort after 10 redirects. *)

(** A handleable client error (Go's [Client.Do] returning an error):
    [Redirect msg] — the redirect policy ([CheckRedirect]) aborted the request;
    [Round_trip e] — a per-hop {!Transport.round_trip} failed, embedding the
    transport's typed {!Transport.error}; [Timeout] — the whole exchange
    exceeded [Client.timeout] (Go's [Client.Timeout]). Returned as [Error _]
    from the result-typed public API ({!send}/{!get}/{!head}/{!post}). *)
type error = Redirect of string | Round_trip of Transport.error | Timeout

val error_to_string : error -> string
(** Render an {!error}: [Redirect msg] as its Go message text (with the
    ["http: "] prefix), [Round_trip e] via {!Transport.error_to_string},
    [Timeout] as ["http: timeout"]. *)

type t
(** A [Client] wrapping a {!Transport.t}, a redirect policy and an optional
    overall timeout (Go's [Client.Timeout]). *)

val create :
  net:_ Eio.Net.t ->
  ?clock:_ Eio.Time.clock ->
  ?transport:Transport.t ->
  ?check_redirect:check_redirect ->
  ?timeout:float ->
  ?insecure:bool ->
  ?authenticator:X509.Authenticator.t ->
  unit ->
  t
(** [create ~net ?clock ?transport ?check_redirect ?timeout ?insecure
     ?authenticator ()] builds a client capturing the [net] capability (and
    optional [clock]). Defaults: a fresh {!Transport.create},
    {!default_check_redirect}, no timeout, and
    {b TLS verification secure by default}, mirroring Go's [http.Client].

    [?insecure]/[?authenticator] set the TLS verification policy (see
    {!Transport.create}); they take effect only when no explicit [?transport] is
    given. [?timeout] (seconds) bounds the whole exchange and is enforced only
    when a [?clock] was captured (Go's [Client.Timeout]). *)

val send :
  ?force_h2:bool ->
  sw:Eio.Switch.t ->
  t ->
  Request.t ->
  (Response.t, error) result
(** [send ~sw c req] is Go's [Client.Do]: send [req], following redirects per
    the client's policy (301/302/303 rewrite the method to GET unless the
    original was GET/HEAD and drop the body; 307/308 preserve method and body),
    composing {!Transport.round_trip} for each hop. A non-2xx status is {b not}
    an error — it is returned as [Ok resp]. Handleable failures are returned as
    [Error]: [Error (Redirect msg)] when the redirect policy aborts, and
    [Error (Round_trip e)] when a hop's {!Transport.round_trip} fails.

    {b Residual raise:} when the client carries a [timeout] and a [clock] was
    captured, the exchange is bounded by {!Net.with_timeout}, which still
    {b raises} [Eio.Time.Timeout] on deadline expiry (an Eio control-flow
    signal, not converted to an [Error] arm).

    [force_h2] (default [false]) is forwarded to {!Transport.round_trip}: for an
    ["http"] (cleartext) request it selects h2c via prior knowledge (RFC 9113
    §3.3) instead of HTTP/1.x; for ["https"] HTTP/2 is already negotiated by
    ALPN. Symmetric with {!Server.create}'s [?force_h2].

    The captured [net] drives {!Transport.round_trip} (dialing + pooled
    connection fibers). Per-request cancellation is expressed via the caller's
    [sw] (Go's [?context] is dropped in this port).

    {b The response body streams} (a {!Body.Stream}): it is not buffered, and
    the underlying connection is returned to the transport pool only after the
    caller consumes the body to EOF ({!Body.read_all}/{!Body.drain}). The
    redirect loop drains each intermediate hop's body before following. *)

val get : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [get ~sw c url] is Go's [Client.Get]: forwards to {!send}. A non-2xx status
    is [Ok resp]; only transport/redirect failures are [Error]. *)

val head : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [head ~sw c url] is Go's [Client.Head]: forwards to {!send}. A non-2xx
    status is [Ok resp]; only transport/redirect failures are [Error]. *)

val delete : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [delete ~sw c url] sends a body-less DELETE (forwards to {!send}). A non-2xx
    status is [Ok resp]; only transport/redirect failures are [Error]. *)

val options : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [options ~sw c url] sends a body-less OPTIONS (forwards to {!send}). A
    non-2xx status is [Ok resp]; only transport/redirect failures are [Error].
*)

val trace : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [trace ~sw c url] sends a body-less TRACE (forwards to {!send}). A non-2xx
    status is [Ok resp]; only transport/redirect failures are [Error]. *)

val connect : sw:Eio.Switch.t -> t -> string -> (Response.t, error) result
(** [connect ~sw c url] sends a body-less CONNECT (forwards to {!send}). A
    non-2xx status is [Ok resp]; only transport/redirect failures are [Error].
*)

val post :
  sw:Eio.Switch.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  (Response.t, error) result
(** [post ~sw c url ~content_type body] is Go's [Client.Post]: POST [body] with
    the given Content-Type. A non-2xx status is [Ok resp]; only
    transport/redirect failures are [Error]. *)

val put :
  sw:Eio.Switch.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  (Response.t, error) result
(** [put ~sw c url ~content_type body] sends a PUT carrying [body] with the
    given Content-Type (the body-bearing analogue of {!post}). A non-2xx status
    is [Ok resp]; only transport/redirect failures are [Error]. *)

val patch :
  sw:Eio.Switch.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  (Response.t, error) result
(** [patch ~sw c url ~content_type body] sends a PATCH (RFC 5789) carrying
    [body] with the given Content-Type (the body-bearing analogue of {!post}). A
    non-2xx status is [Ok resp]; only transport/redirect failures are [Error].
*)

module Private : sig
  (** Exposed only for the ported white-box tests; not part of the public API.
  *)

  val do_one :
    ?round_trip:(Request.t -> (Response.t, Transport.error) result) ->
    ?force_h2:bool ->
    t ->
    Request.t ->
    (Response.t, error) result
  (** Go's unexported [Client.do]: the redirect-following loop (without
      {!send}'s timeout composition). [?round_trip] overrides the per-hop
      round-tripper (default: the client's {!Transport.round_trip}, passing
      [?force_h2]), exposed so the loop can be driven against a stub without
      real DNS (the stub returns [Ok resp]/[Error _]; the result threads through
      the loop). With the default round-tripper the transport switch must be
      established ({!Transport.run}); {!send} does this. A round-trip failure
      surfaces as [Error (Round_trip e)], a policy abort as
      [Error (Redirect msg)]. Sensitive headers are stripped stickily and
      subdomain-aware against the initial host (client.go:691-694); the Referer
      is set from the previous hop. *)
end
