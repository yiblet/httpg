(* Port of go/src/net/http/internal/http2/api.go: the decoupled types the HTTP/2
   stack uses so it never names net/http (httpg) types. The public library's
   shims translate Request.t/Response.t to and from these. See api.ml. *)

type header = (string, string list) Hashtbl.t

(* The textproto.MIMEHeader method subset the HTTP/2 stack uses. *)
module Header : sig
  type t = header

  val create : unit -> t
  val canonical_header_key : string -> string
  val add : t -> string -> string -> unit
  val get : t -> string -> string
  val values : t -> string -> string list
  val to_list : t -> (string * string list) list
  val del : t -> string -> unit
  val has : t -> string -> bool
end

(* The http2 body abstraction (Go's io.ReadCloser body). *)
module Body : sig
  type t = Empty | String of string | Stream of (unit -> string option)

  val empty : t
  val of_string : string -> t
  val of_stream : (unit -> string option) -> t

  (* Pull the whole body to a string (EOF at the first [None]). *)
  val read_all : t -> string
end

val default_user_agent : string

type client_request = {
  creq_meth : Httpg_base.Method.t;
  creq_url : Uri.t;
  creq_header : header;
  creq_trailer : header;
  creq_body : Body.t;
  creq_host : string;
  creq_content_length : int64;
  creq_close : bool;
}

type client_response = {
  cres_status_code : Httpg_base.Status.t;
  cres_content_length : int64;
  cres_uncompressed : bool;
  cres_header : header;
  cres_trailer : header;
  cres_body : Body.t;
}

type server_request = {
  sreq_proto : string;
  sreq_proto_major : int;
  sreq_proto_minor : int;
  sreq_meth : Httpg_base.Method.t;
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
  rw_write : string -> unit;
  rw_flush : unit -> unit;
}

type handler = response_writer -> server_request -> unit
