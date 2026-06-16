(* Port of go/src/net/http/internal/http2/databuffer.go *)

type t
(** [dataBuffer] is a ReadWriter backed by a list of data chunks. Used to read
    DATA frames on a single stream. The buffer is divided into size-classed
    chunks so a connection can bound its total memory without limiting any one
    stream's body size. Mirrors Go's [dataBuffer]. *)

val create : ?expected:int64 -> unit -> t
(** [create ?expected ()] is a fresh empty buffer. [expected] (default 0)
    mirrors Go's [dataBuffer.expected]: a hint of at least this many bytes in
    future writes, used to size the next chunk (ignored when <= 0). *)

val len : t -> int
(** [len b] is the number of unread bytes. Mirrors [dataBuffer.Len]. *)

val read : t -> bytes -> int -> int -> int option
(** [read b p off plen] copies up to [plen] bytes into [p] starting at [off],
    returning [Some n] with the count copied, or [None] when [b] is empty
    (mirrors Go's [errReadEmpty] sentinel). Mirrors [dataBuffer.Read]. *)

val write : t -> bytes -> int -> int -> int
(** [write b p off plen] appends [plen] bytes of [p] (from [off]) to the buffer,
    returning [plen]. Mirrors [dataBuffer.Write]. *)

val write_string : t -> string -> int
(** [write_string b s] appends [s], returning its length. *)

val read_string : t -> int -> string option
(** [read_string b n] reads up to [n] bytes, returning [Some s], or [None] when
    [b] is empty (mirrors Go's [errReadEmpty] sentinel). *)
