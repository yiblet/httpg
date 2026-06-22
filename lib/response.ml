(* Port of go/src/net/http/response.go: the Response type and pure helpers.
   The TLS field is intentionally omitted (deferred).

   v2 of {!Response}: same record, plus an immutable builder
   ([create]/[with_*]) so axum-style handlers build a response and return it
   instead of mutating a writer. Migrated in via the parallel-module pattern
   (docs/module-rewrite-pattern.md); will be renamed to [Response]. *)

type t = {
  mutable status : Httpg_base.Status.t;
      (** Go [Status]/[StatusCode], collapsed; the wire reason phrase is the
          canonical {!Httpg_base.Status.to_string} *)
  mutable proto : Httpg_base.Protocol.t;
      (** Go [Proto]/[ProtoMajor]/[ProtoMinor], collapsed *)
  mutable header : Header.t;
  mutable body : Body.t;
  mutable content_length : int64 option;  (** None = unknown (Go's -1) *)
  mutable transfer_encoding : string list;
  mutable close : bool;
  mutable uncompressed : bool;
  mutable trailer : Header.t option;
  mutable request : Request.t option;
}

(* --- Immutable builder (axum-style). Handlers build a Response with these and
   return it; the server runtime flushes it. Each [with_*] returns a new value;
   [with_header]/[with_set_header] copy-on-write the header so a base response is
   never mutated by deriving from it. --- *)

let create () : t =
  {
    status = Httpg_base.Status.Ok;
    proto = Httpg_base.Protocol.Http11;
    header = Header.empty;
    body = Body.empty;
    content_length = Some 0L;
    transfer_encoding = [];
    close = false;
    uncompressed = false;
    trailer = None;
    request = None;
  }

let with_status code (r : t) : t = { r with status = code }

let with_header key value (r : t) : t =
  { r with header = Header.add key value r.header }

let with_set_header key value (r : t) : t =
  { r with header = Header.set key value r.header }

(* Inherit the body's known length when it has one (a string/in-memory body or
   a concatenation of known-length bodies); a streaming body of unknown length
   ([Body.content_length = None]) stays unknown and is framed chunked. A caller
   with a known-length stream can still set [content_length] explicitly
   afterwards (e.g. the file server's byte ranges). *)
let with_body ?content_type ?content_length (body : Body.t) (r : t) : t =
  let r =
    {
      r with
      body;
      content_length =
        (match content_length with
        | None -> Body.content_length body
        | Some n when n < 0L -> Body.content_length body
        | Some n -> Some n);
    }
  in
  match content_type with
  | None -> r
  | Some ct -> with_header "Content-Type" ct r

let with_body_string ?content_type ?content_length s (r : t) : t =
  with_body ?content_length ?content_type (Body.of_string s) r

let with_trailer t (r : t) : t = { r with trailer = Some t }

(* Response.Cookies. *)
let cookies (r : t) = Cookie.read_set_cookies r.header

(* Response.ProtoAtLeast. *)
let proto_at_least (r : t) major minor =
  Httpg_base.Protocol.at_least r.proto major minor

(* Response.Location: the "Location" header resolved against the request URL.
   Returns None when no Location header is present (Go's ErrNoLocation). *)
let location (r : t) : Uri.t option =
  match Header.get r.header "Location" with
  | None -> None
  | Some lv -> (
      let loc = Uri.of_string lv in
      match r.request with
      | Some req ->
          Some
            (Uri.resolve
               (Uri.scheme req.Request.url |> Option.value ~default:"http")
               req.Request.url loc)
      | None -> Some loc)
