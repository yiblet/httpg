(* Port of go/src/net/http/internal/http2/databuffer.go *)

(** Raised by {!read}/{!read_string} when no data is available. Mirrors Go's
    [errReadEmpty] ("read from empty dataBuffer"). *)
exception Read_empty

(** The message text of Go's [errReadEmpty]. *)
val read_empty_msg : string

(** [dataBuffer] is a ReadWriter backed by a list of data chunks. Used to read
    DATA frames on a single stream. The buffer is divided into size-classed
    chunks so a connection can bound its total memory without limiting any one
    stream's body size. Mirrors Go's [dataBuffer]. *)
type t

(** [create ?expected ()] is a fresh empty buffer. [expected] (default 0)
    mirrors Go's [dataBuffer.expected]: a hint of at least this many bytes in
    future writes, used to size the next chunk (ignored when <= 0). *)
val create : ?expected:int64 -> unit -> t

(** [len b] is the number of unread bytes. Mirrors [dataBuffer.Len]. *)
val len : t -> int

(** [read b p off plen] copies up to [plen] bytes into [p] starting at [off],
    returning the count copied. Raises {!Read_empty} when [b] is empty. Mirrors
    [dataBuffer.Read]. *)
val read : t -> bytes -> int -> int -> int

(** [write b p off plen] appends [plen] bytes of [p] (from [off]) to the
    buffer, returning [plen]. Mirrors [dataBuffer.Write]. *)
val write : t -> bytes -> int -> int -> int

(** [write_string b s] appends [s], returning its length. *)
val write_string : t -> string -> int

(** [read_string b n] reads up to [n] bytes, returning them as a string.
    Raises {!Read_empty} when [b] is empty. *)
val read_string : t -> int -> string
