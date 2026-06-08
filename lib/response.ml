(* Port of go/src/net/http/response.go: the Response type and pure helpers.
   The body field is parametric; {!Io} instantiates ['body] to {!Body.t}.
   The TLS field is intentionally omitted (deferred).

   v2 of {!Response}: same record, plus an immutable builder
   ([create]/[with_*]) so axum-style handlers build a response and return it
   instead of mutating a writer. Migrated in via the parallel-module pattern
   (docs/module-rewrite-pattern.md); will be renamed to [Response]. *)

type 'body t = {
  mutable status : Httpg_base.Status.t;
      (** Go [Status]/[StatusCode], collapsed; the wire reason phrase is the
          canonical {!Httpg_base.Status.to_string} *)
  mutable proto : Httpg_base.Protocol.t;
      (** Go [Proto]/[ProtoMajor]/[ProtoMinor], collapsed *)
  mutable header : Header.t;
  mutable body : 'body;
  mutable content_length : int64;  (** -1 means unknown *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable uncompressed : bool;
  mutable trailer : Header.t option;
  mutable request : 'body Request.t option;
}

(* --- Immutable builder (axum-style). Handlers build a Response with these and
   return it; the server runtime flushes it. Each [with_*] returns a new value;
   [with_header]/[with_set_header] copy-on-write the header so a base response is
   never mutated by deriving from it. --- *)

let create () : Body.t t =
  {
    status = Httpg_base.Status.Ok;
    proto = Httpg_base.Protocol.Http11;
    header = Header.create ();
    body = Body.Empty;
    content_length = 0L;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = None;
  }

let with_status code (r : 'b t) : 'b t = { r with status = code }

let with_header key value (r : 'b t) : 'b t =
  let h = Header.clone r.header in
  Header.add h key value;
  { r with header = h }

let with_set_header key value (r : 'b t) : 'b t =
  let h = Header.clone r.header in
  Header.set h key value;
  { r with header = h }

let content_length_of_body = function
  | Body.String s -> Int64.of_int (String.length s)
  | Body.Empty -> 0L
  | Body.Stream _ -> -1L

let with_body (body : Body.t) (r : Body.t t) : Body.t t =
  { r with body; content_length = content_length_of_body body }

let with_body_string s (r : Body.t t) : Body.t t = with_body (Body.String s) r
let with_trailer t (r : 'b t) : 'b t = { r with trailer = Some t }

(* Response.Cookies. *)
let cookies (r : 'a t) = Cookie.read_set_cookies r.header

(* Response.ProtoAtLeast. *)
let proto_at_least (r : 'a t) major minor =
  Httpg_base.Protocol.at_least r.proto major minor

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
