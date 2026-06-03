(* Port of the HTTP/1.x subset of go/src/net/http/client.go: the Client, its
   Do entry point with redirect following, and the Get/Post/Head convenience
   verbs. *)

(** A redirect policy (Go's [CheckRedirect]): given the requests made so far
    ([via], most recent last), [Ok ()] permits the next hop and [Error msg]
    aborts (Go returns an error). *)
type check_redirect = Body.t Request.t list -> (unit, string) result

(** Go's [defaultCheckRedirect]: abort after 10 redirects. *)
val default_check_redirect : check_redirect

(** A [Client] wrapping a {!Transport.t}, a redirect policy and an optional
    overall timeout (Go's [Client.Timeout]). *)
type t

(** [create ?transport ?check_redirect ?timeout ?insecure ?authenticator ()]
    builds a client. Defaults: {!Transport.default_transport},
    {!default_check_redirect}, no timeout, and {b TLS verification secure by
    default} (system trust + hostname), mirroring Go's [http.Client].

    [?insecure]/[?authenticator] set the TLS verification policy (see
    {!Transport.create}): [?insecure:true] disables verification (Go's
    [InsecureSkipVerify], for self-signed/loopback test servers);
    [?authenticator] supplies an explicit one. They take effect only when no
    explicit [?transport] is given (an explicit transport already carries its
    own policy); supplying any override with no transport builds a fresh
    transport carrying it instead of the shared default. *)
val create :
  ?transport:Transport.t ->
  ?check_redirect:check_redirect ->
  ?timeout:float ->
  ?insecure:bool ->
  ?authenticator:X509.Authenticator.t ->
  unit ->
  t

(** Go's [DefaultClient]. *)
val default_client : t

(** [do_ c req] is Go's [Client.Do]: send [req], following redirects per the
    client's policy (301/302/303 rewrite the method to GET unless the original
    was GET/HEAD and drop the body; 307/308 preserve method and body), composing
    {!Transport.round_trip} for each hop. A non-2xx status is not an error.
    Raises [Failure] when the redirect policy aborts.

    The optional [?context] (Go's per-request [context.Context]) is applied to
    [req] before the exchange; when omitted the request keeps its existing
    context (defaulting to {!Context.background}). When the client carries a
    [timeout], it composes over the effective context as a deadline (Go's
    [setRequestCancel]). *)
val do_ :
  ?context:Context.t -> t -> Body.t Request.t -> Body.t Response.t Lwt.t

(** [make_request ?body ?content_length meth url] builds a request from a URL
    string (Go's [NewRequest]). The default body is empty. *)
val make_request :
  ?body:Body.t -> ?content_length:int64 -> string -> string -> Body.t Request.t

(** [get ?context c url] is Go's [Client.Get]. The optional [?context] is
    applied to the built request (defaulting to {!Context.background}). *)
val get : ?context:Context.t -> t -> string -> Body.t Response.t Lwt.t

(** [head ?context c url] is Go's [Client.Head]. *)
val head : ?context:Context.t -> t -> string -> Body.t Response.t Lwt.t

(** [post ?context c url ~content_type body] is Go's [Client.Post]: POST [body]
    with the given Content-Type. *)
val post :
  ?context:Context.t ->
  t ->
  string ->
  content_type:string ->
  Body.t ->
  Body.t Response.t Lwt.t
