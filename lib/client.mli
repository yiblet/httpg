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

(** [create ?transport ?check_redirect ?timeout ()] builds a client. Defaults:
    {!Transport.default_transport}, {!default_check_redirect}, no timeout. *)
val create :
  ?transport:Transport.t ->
  ?check_redirect:check_redirect ->
  ?timeout:float ->
  unit ->
  t

(** Go's [DefaultClient]. *)
val default_client : t

(** [do_ c req] is Go's [Client.Do]: send [req], following redirects per the
    client's policy (301/302/303 rewrite the method to GET unless the original
    was GET/HEAD and drop the body; 307/308 preserve method and body), composing
    {!Transport.round_trip} for each hop. A non-2xx status is not an error.
    Raises [Failure] when the redirect policy aborts. *)
val do_ : t -> Body.t Request.t -> Body.t Response.t Lwt.t

(** [make_request ?body ?content_length meth url] builds a request from a URL
    string (Go's [NewRequest]). The default body is empty. *)
val make_request :
  ?body:Body.t -> ?content_length:int64 -> string -> string -> Body.t Request.t

(** [get c url] is Go's [Client.Get]. *)
val get : t -> string -> Body.t Response.t Lwt.t

(** [head c url] is Go's [Client.Head]. *)
val head : t -> string -> Body.t Response.t Lwt.t

(** [post c url ~content_type body] is Go's [Client.Post]: POST [body] with the
    given Content-Type. *)
val post : t -> string -> content_type:string -> Body.t -> Body.t Response.t Lwt.t
