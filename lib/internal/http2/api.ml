(* Port of go/src/net/http/internal/http2/api.go.

   Since net/http imports the http2 package, http2 cannot use any net/http
   types. This module holds the decoupled request/response/header/body types the
   HTTP/2 server and client work with; the thin shims in the public library
   (lib/server.ml, lib/transport.ml) translate net/http's Request.t/Response.t
   to and from these — mirroring Go's net/http/http2.go.

   Record fields are prefixed (creq_/cres_/sreq_/rw_) so the several records can
   share concepts (header, body, host, …) without field-name ambiguity. *)

(* Go: type Header = textproto.MIMEHeader. Same structural Hashtbl as the public
   Gohttp.Header.t, so the shim passes it through with no conversion. *)
type header = (string, string list) Hashtbl.t

(* The textproto.MIMEHeader method subset the HTTP/2 stack uses. *)
module Header = struct
  type t = header

  let create () : t = Hashtbl.create 8
  let canonical_header_key = Gohttp_base.Textproto.canonical_mime_header_key
  let find_opt (h : t) k = Hashtbl.find_opt h k

  let add (h : t) k v =
    let k = canonical_header_key k in
    match find_opt h k with
    | Some vs -> Hashtbl.replace h k (vs @ [ v ])
    | None -> Hashtbl.replace h k [ v ]

  let get h k =
    match find_opt h (canonical_header_key k) with
    | Some (v :: _) -> v
    | _ -> ""

  let values h k =
    match find_opt h (canonical_header_key k) with Some vs -> vs | None -> []

  let to_list (h : t) = Hashtbl.fold (fun k vs acc -> (k, vs) :: acc) h []
  let del h k = Hashtbl.remove h (canonical_header_key k)
  let has h k = Hashtbl.mem h (canonical_header_key k)
end

(* The http2 body abstraction (Go's io.ReadCloser body), mirroring the public
   Body.t variant so the shim maps the two with a trivial case split. *)
module Body = struct
  type t = Empty | String of string | Stream of (unit -> string option Lwt.t)

  let empty = Empty
  let of_string s = String s
  let of_stream next = Stream next

  let read_all = function
    | Empty -> Lwt.return ""
    | String s -> Lwt.return s
    | Stream next ->
        let buf = Buffer.create 256 in
        let rec pump () =
          Lwt.bind (next ()) (function
            | None -> Lwt.return (Buffer.contents buf)
            | Some s ->
                Buffer.add_string buf s;
                pump ())
        in
        pump ()
end

(* Go http2 transport's defaultUserAgent. *)
let default_user_agent = "Go-http-client/1.1"

(* A ClientRequest is a Request used by the HTTP/2 client (Transport). *)
type client_request = {
  creq_ctx : Gohttp_base.Context.t;
  creq_meth : string;
  creq_url : Uri.t;
  creq_header : header;
  creq_trailer : header;
  creq_body : Body.t;
  creq_host : string;
  creq_content_length : int64;
  creq_close : bool;
}

(* A ClientResponse is a Response produced by the HTTP/2 client. The status TEXT
   (Status.status_text) is applied by the shim, so only the code travels here. *)
type client_response = {
  cres_status_code : int;
  cres_content_length : int64;
  cres_uncompressed : bool;
  cres_header : header;
  cres_trailer : header;
  cres_body : Body.t;
}

(* A ServerRequest is a Request used by the HTTP/2 server. *)
type server_request = {
  sreq_ctx : Gohttp_base.Context.t;
  sreq_proto : string;
  sreq_proto_major : int;
  sreq_proto_minor : int;
  sreq_meth : string;
  sreq_url : Uri.t;
  sreq_header : header;
  sreq_trailer : header;
  mutable sreq_body : Body.t;
  sreq_host : string;
  sreq_content_length : int64;
  sreq_remote_addr : string;
  sreq_request_uri : string;
}

type response_writer = {
  rw_header : unit -> header;
  rw_write_header : int -> unit;
  rw_write : string -> unit Lwt.t;
  rw_flush : unit -> unit Lwt.t;
}

type handler = response_writer -> server_request -> unit Lwt.t
