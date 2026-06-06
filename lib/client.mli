(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client, its
   Do entry point with redirect following, and the Get/Post/Head convenience
   verbs. *)

type check_redirect = Body.t Request.t list -> (unit, string) result
(** A redirect policy (Go's [CheckRedirect]): given the requests made so far
    ([via], most recent last), [Ok ()] permits the next hop and [Error msg]
    aborts (Go returns an error). *)

val default_check_redirect : check_redirect
(** Go's [defaultCheckRedirect]: abort after 10 redirects. *)

(** A handleable client error: the redirect policy aborted the request (Go's
    [Client.Do] returning the [CheckRedirect] error). *)
type error = Redirect of string

val error_to_string : error -> string
(** Render an {!error} as its Go message text (with the ["http: "] prefix). *)

exception Aborted of error
(** Raised by {!do_} (and the convenience verbs) when the redirect policy aborts
    the request — the handleable {!error} carried as an exception, since
    {!do_}/{!get}/{!post}/{!head} keep Go's [Response]/[error] split as a
    raising [Body.t Response.t Lwt.t] boundary. *)

type t
(** A [Client] wrapping a {!Transport.t}, a redirect policy and an optional
    overall timeout (Go's [Client.Timeout]). *)

val create :
  ?transport:Transport.t ->
  ?check_redirect:check_redirect ->
  ?timeout:float ->
  ?insecure:bool ->
  ?authenticator:X509.Authenticator.t ->
  unit ->
  t
(** [create ?transport ?check_redirect ?timeout ?insecure ?authenticator ()]
    builds a client. Defaults: {!Transport.default_transport},
    {!default_check_redirect}, no timeout, and
    {b TLS verification secure by default} (system trust + hostname), mirroring
    Go's [http.Client].

    [?insecure]/[?authenticator] set the TLS verification policy (see
    {!Transport.create}): [?insecure:true] disables verification (Go's
    [InsecureSkipVerify], for self-signed/loopback test servers);
    [?authenticator] supplies an explicit one. They take effect only when no
    explicit [?transport] is given (an explicit transport already carries its
    own policy); supplying any override with no transport builds a fresh
    transport carrying it instead of the shared default. *)

val default_client : t
(** Go's [DefaultClient]. *)

val do_ : ?context:Context.t -> t -> Body.t Request.t -> Body.t Response.t Lwt.t
(** [do_ c req] is Go's [Client.Do]: send [req], following redirects per the
    client's policy (301/302/303 rewrite the method to GET unless the original
    was GET/HEAD and drop the body; 307/308 preserve method and body), composing
    {!Transport.round_trip} for each hop. A non-2xx status is not an error.
    Raises {!Aborted} (carrying the typed {!error}) when the redirect policy
    aborts.

    {b The response body streams} (a {!Body.Stream}, see
    {!Transport.round_trip}): it is not buffered, and the underlying connection
    is returned to the transport pool only after the caller consumes the body to
    EOF ({!Body.read_all} or {!Body.drain}, the analogue of [resp.Body.Close]).
    The redirect loop drains each intermediate hop's body before following, so
    the hop's connection is released for reuse.

    The optional [?context] (Go's per-request [context.Context]) is applied to
    [req] before the exchange; when omitted the request keeps its existing
    context (defaulting to {!Context.background}). When the client carries a
    [timeout], it composes over the effective context as a deadline (Go's
    [setRequestCancel]) — and the deadline {b covers the streaming body read},
    not just the headers: the timer is disarmed when the body reaches EOF or
    fails (Go's [cancelTimerBody]), and a body read outstanding when the
    deadline fires aborts with the timeout cause. *)

val is_domain_or_subdomain : sub:string -> parent:string -> bool
(** Go's [isDomainOrSubdomain] (client.go:1026-1048): whether host [sub] is a
    subdomain of, or an exact match for, [parent]. Both must be in canonical
    (hostname, no port) form. A [:] or [%] in [sub] (an IPv6 literal/zone) never
    matches; otherwise [sub] must end in ["." ^ parent]. Exposed for the
    redirect sensitive-header policy. *)

val should_copy_header_on_redirect : initial:Uri.t -> dest:Uri.t -> bool
(** Go's [shouldCopyHeaderOnRedirect] (client.go:1008-1024): whether sensitive
    headers (Authorization/Cookie/...) may be copied onto a redirect from the
    [initial] request URL to the [dest] URL — true iff [dest]'s host is the
    [initial] host or a subdomain of it. (No IDNA normalization: hosts are used
    as-is, matching Go's [idnaASCII] no-error fallback.) *)

val referer_for_url :
  last:Uri.t -> next:Uri.t -> explicit:string -> string option
(** Go's [refererForURL] (client.go:147-170): the Referer to set on the next hop
    given the previous hop's URL [last] and the destination [next]. [None] (omit
    the Referer) when [last] is https and [next] is http; otherwise [Some] the
    [explicit] Referer if the user set one on the original request, else [last]
    with any userinfo stripped. *)

val do_one :
  ?round_trip:(Body.t Request.t -> Body.t Response.t Lwt.t) ->
  t ->
  Body.t Request.t ->
  Body.t Response.t Lwt.t
(** Go's [Client.do]: the redirect-following loop (without {!do_}'s timeout
    composition). [?round_trip] overrides the per-hop round-tripper (default:
    the client's {!Transport.round_trip}); it is exposed so the redirect loop
    can be driven against a stub that captures per-hop headers and returns
    canned redirects, without real DNS. Sensitive headers are stripped stickily
    and subdomain-aware against the initial request host (client.go:691-694),
    and the Referer is set from the previous hop (client.go:698). *)

val make_request :
  ?body:Body.t -> ?content_length:int64 -> string -> string -> Body.t Request.t
(** [make_request ?body ?content_length meth url] builds a request from a URL
    string (Go's [NewRequest]). The default body is empty. *)

val get : ?context:Context.t -> t -> string -> Body.t Response.t Lwt.t
(** [get ?context c url] is Go's [Client.Get]. The optional [?context] is
    applied to the built request (defaulting to {!Context.background}). *)

val head : ?context:Context.t -> t -> string -> Body.t Response.t Lwt.t
(** [head ?context c url] is Go's [Client.Head]. *)

val post :
  ?context:Context.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  Body.t Response.t Lwt.t
(** [post ?context c url ~content_type body] is Go's [Client.Post]: POST [body]
    with the given Content-Type. *)
