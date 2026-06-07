(* Port of go/src/net/http/response.go: the Response type and pure helpers.
   The body field is parametric; {!Io} instantiates ['body] to {!Body.t}.
   The TLS field is intentionally omitted (deferred). *)

type 'body t = {
  mutable status : string;  (** e.g. "200 OK" *)
  mutable status_code : Httpg_base.Status.t;  (** e.g. 200 *)
  mutable proto : string;  (** e.g. "HTTP/1.0" *)
  mutable proto_major : int;
  mutable proto_minor : int;
  mutable header : Header.t;
  mutable body : 'body;
  mutable content_length : int64;  (** -1 means unknown *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable uncompressed : bool;
  mutable trailer : Header.t option;
  mutable request : 'body Request.t option;
}

(* Response.Cookies. *)
let cookies (r : 'a t) = Cookie.read_set_cookies r.header

(* Response.ProtoAtLeast. *)
let proto_at_least (r : 'a t) major minor =
  r.proto_major > major || (r.proto_major = major && r.proto_minor >= minor)

(* Response.Location: the "Location" header resolved against the request URL.
   Returns None when no Location header is present (Go's ErrNoLocation). *)
let location (r : 'a t) : Uri.t option =
  match Header.get r.header "Location" with
  | "" -> None
  | lv -> (
      let loc = Uri.of_string lv in
      match r.request with
      | Some req ->
          Some
            (Uri.resolve
               (Uri.scheme req.Request.url |> Option.value ~default:"http")
               req.Request.url loc)
      | None -> Some loc)
