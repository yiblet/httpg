(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client, its
   Do entry point with redirect following, and the Get/Post/Head convenience
   verbs. *)

type check_redirect = Body.t Request.t list -> (unit, string) result
(** A redirect policy (Go's [CheckRedirect]): given the requests made so far
    ([via], most recent last), [Ok ()] permits the next hop and [Error msg]
    aborts. *)

val default_check_redirect : check_redirect
(** Go's [defaultCheckRedirect]: abort after 10 redirects. *)

(** A handleable client error: the redirect policy aborted the request (Go's
    [Client.Do] returning the [CheckRedirect] error). *)
type error = Redirect of string

val error_to_string : error -> string
(** Render an {!error} as its Go message text (with the ["http: "] prefix). *)

exception Aborted of error
(** Raised by {!do_} (and the convenience verbs) when the redirect policy aborts
    the request — the handleable {!error} carried as an exception, since the
    verbs keep Go's [Response]/[error] split as a raising boundary. *)

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

val do_ : sw:Eio.Switch.t -> t -> Body.t Request.t -> Body.t Response.t
(** [do_ ~sw c req] is Go's [Client.Do]: send [req], following redirects per the
    client's policy (301/302/303 rewrite the method to GET unless the original
    was GET/HEAD and drop the body; 307/308 preserve method and body), composing
    {!Transport.round_trip} for each hop. A non-2xx status is not an error.
    Raises {!Aborted} when the redirect policy aborts.

    The captured [net] drives {!Transport.round_trip} (dialing + pooled
    connection fibers). When the client carries a [timeout] and a [clock] was
    captured, the exchange is bounded by {!Net.with_timeout} (raising
    [Eio.Time.Timeout]); per-request cancellation is otherwise expressed via the
    caller's [sw] (Go's [?context] is dropped in this port).

    {b The response body streams} (a {!Body.Stream}): it is not buffered, and
    the underlying connection is returned to the transport pool only after the
    caller consumes the body to EOF ({!Body.read_all}/{!Body.drain}). The
    redirect loop drains each intermediate hop's body before following. *)

val is_domain_or_subdomain : sub:string -> parent:string -> bool
(** Go's [isDomainOrSubdomain] (client.go:1026-1048): whether host [sub] is a
    subdomain of, or an exact match for, [parent]. Both in canonical (hostname,
    no port) form. Exposed for the redirect sensitive-header policy. *)

val should_copy_header_on_redirect : initial:Uri.t -> dest:Uri.t -> bool
(** Go's [shouldCopyHeaderOnRedirect] (client.go:1008-1024): whether sensitive
    headers may be copied onto a redirect from [initial] to [dest] — true iff
    [dest]'s host is [initial]'s host or a subdomain of it. *)

val referer_for_url :
  last:Uri.t -> next:Uri.t -> explicit:string -> string option
(** Go's [refererForURL] (client.go:147-170): the Referer for the next hop given
    the previous hop's URL [last] and the destination [next]. [None] on
    https->http; otherwise the [explicit] Referer if set, else [last] with
    userinfo stripped. *)

val do_one :
  ?round_trip:(Body.t Request.t -> Body.t Response.t) ->
  t ->
  Body.t Request.t ->
  Body.t Response.t
(** Go's [Client.do]: the redirect-following loop (without {!do_}'s timeout
    composition). [?round_trip] overrides the per-hop round-tripper (default:
    the client's {!Transport.round_trip}); exposed so the redirect loop can be
    driven against a stub without real DNS. With the default round-tripper the
    transport's switch must be established ({!Transport.run}); {!do_} does this.
    Sensitive headers are stripped stickily and subdomain-aware against the
    initial request host (client.go:691-694); the Referer is set from the
    previous hop. *)

val make_request :
  ?body:Body.t ->
  ?content_length:int64 ->
  Httpg_base.Method.t ->
  string ->
  Body.t Request.t
(** [make_request ?body ?content_length meth url] builds a request from a URL
    string (Go's [NewRequest]). The default body is empty. *)

val get : sw:Eio.Switch.t -> t -> string -> Body.t Response.t
(** [get ~sw c url] is Go's [Client.Get]. *)

val head : sw:Eio.Switch.t -> t -> string -> Body.t Response.t
(** [head ~sw c url] is Go's [Client.Head]. *)

val post :
  sw:Eio.Switch.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  Body.t Response.t
(** [post ~sw c url ~content_type body] is Go's [Client.Post]: POST [body] with
    the given Content-Type. *)
