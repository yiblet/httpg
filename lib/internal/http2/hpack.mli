(* Port of golang.org/x/net/http2/hpack/encode.go (Encoder) and hpack.go
   (Decoder) — the HPACK representation encode/decode layer. Pure, no IO.
   Composes {!Hpack_huffman} and {!Hpack_tables}. *)

type header_field = Hpack_tables.header_field = {
  name : string;
  value : string;
  sensitive : bool;
}

(* ---- low-level primitives (RFC 7541 sections 5.1 / 5.2) ---- *)

val append_var_int : Buffer.t -> int -> int -> unit
(** [append_var_int buf n i] appends [i] using an [n]-bit prefix integer
    representation to [buf]. Mirrors Go's [appendVarInt]. The high bits of the
    first byte are left zero (the caller ORs in any flag). *)

(* ---- decoder errors ---- *)

(** A handleable HPACK decode error. The arms mirror Go's [DecodingError]
    ([Decoding]), [InvalidIndexError] ([Invalid_indexed]), [ErrStringLength]
    ([String_too_long]), [ErrInvalidHuffman] (propagated from {!Hpack_huffman}
    as [Invalid_huffman]) and the varint-overflow [DecodingError]
    ([Var_int_overflow]). *)
type error =
  | Decoding of string
  | Invalid_indexed of int
  | String_too_long
  | Invalid_huffman
  | Var_int_overflow

val error_to_string : error -> string
(** Renders {!error} as a human-readable string. *)

val read_var_int : int -> string -> int -> (int * int, error) result
(** [read_var_int n s pos] decodes an [n]-bit prefix integer at offset [pos] of
    [s]. Returns [Ok (value, next_pos)] or [Error Var_int_overflow]. Mirrors
    Go's [readVarInt]. [n] must be 1..8 (raises [Invalid_argument] otherwise — a
    programmer error). Raises the internal {!Need_more} sentinel when [s] is
    truncated (see below). *)

exception Need_more
(** Internal control-flow sentinel: the buffer is truncated and more data is
    needed. Mirrors Go's [errNeedMore]. {b Unhandleable / internal only} — used
    by the decoder's incremental {!write} loop to save partial input; it is
    never a caller-visible error and is not part of {!error}. *)

(* ===================== Encoder ===================== *)

type encoder

val new_encoder : unit -> encoder
(** [new_encoder ()] returns a fresh encoder, with an empty dynamic table of the
    initial max size (4096) and an empty output buffer. Mirrors Go's
    [NewEncoder]. *)

val write_field : encoder -> header_field -> unit
(** [write_field e f] encodes [f] (emitting a pending dynamic table size update
    first if required), appending the bytes to the encoder's buffer. Mirrors
    Go's [Encoder.WriteField]. *)

val encoder_bytes : encoder -> string
(** [encoder_bytes e] returns the bytes accumulated so far. Note that, like Go
    (which writes each field to its [io.Writer]), the buffer is reset at the
    start of every {!write_field}; the typical usage is to read the bytes via a
    writer callback. See {!set_writer}. *)

val set_writer : encoder -> (string -> unit) -> unit
(** [set_writer e f] installs a callback invoked with the bytes produced by each
    {!write_field} (mirrors Go's [io.Writer] target). When set, the encoder
    buffer is not accumulated across fields. *)

val encode_to_string : encoder -> header_field list -> string
(** [encode_to_string e fs] is a convenience: encodes the list [fs] into a
    single string using an internal accumulator. *)

val set_max_dynamic_table_size : encoder -> int -> unit
(** [set_max_dynamic_table_size e v] changes the encoder's dynamic table max
    size, bounded by the size limit, scheduling a size update. Mirrors Go's
    [SetMaxDynamicTableSize]. *)

val max_dynamic_table_size : encoder -> int
(** [max_dynamic_table_size e] returns the current dynamic table max size.
    Mirrors Go's [MaxDynamicTableSize]. *)

val set_max_dynamic_table_size_limit : encoder -> int -> unit
(** [set_max_dynamic_table_size_limit e v] changes the upper bound that can be
    passed to {!set_max_dynamic_table_size}. Mirrors Go's
    [SetMaxDynamicTableSizeLimit]. *)

(* ===================== Decoder ===================== *)

type decoder

val new_decoder : int -> (header_field -> unit) -> decoder
(** [new_decoder max_dynamic_table_size emit] returns a new decoder. [emit] is
    called for each decoded field (when emit is enabled), before {!write}
    returns. Mirrors Go's [NewDecoder]. *)

val set_max_string_length : decoder -> int -> unit
(** [set_max_string_length d n] sets the maximum decoded name/value length; 0
    means unlimited. Mirrors Go's [SetMaxStringLength]. *)

val set_emit_func : decoder -> (header_field -> unit) -> unit
(** [set_emit_func d f] replaces the emit callback. Mirrors [SetEmitFunc]. *)

val set_emit_enabled : decoder -> bool -> unit
(** [set_emit_enabled d v] enables/disables the emit callback while still
    keeping decoder state in sync. Mirrors [SetEmitEnabled]. *)

val emit_enabled : decoder -> bool
(** Mirrors [EmitEnabled]. *)

val set_max_dynamic_table_size_dec : decoder -> int -> unit
(** Mirrors [Decoder.SetMaxDynamicTableSize]. *)

val set_allowed_max_dynamic_table_size : decoder -> int -> unit
(** Mirrors [SetAllowedMaxDynamicTableSize]. *)

val write_result : decoder -> string -> (int, error) result
(** [write_result d p] parses as much of [p] as possible, emitting fields.
    Returns [Ok n] where [n] is the number of bytes of [p] consumed (=
    [length p], as in Go: any unparsed tail is saved internally), or [Error] on
    a fatal decoding error. This is the incremental [result] entrypoint used by
    the HTTP/2 meta-headers assembly. Mirrors Go's [Decoder.Write]. *)

val close_result : decoder -> (unit, error) result
(** [close_result d] declares the current header block complete and resets for
    reuse, returning [Error (Decoding _)] on truncated headers. Mirrors Go's
    [Decoder.Close]. *)

val write : decoder -> string -> int
(** [write d p] is {!write_result} but {b raises} on a fatal decoding error (the
    internal decode exceptions). The incremental, raise-based contract is
    retained for the incremental decoder API (Go's [Decoder.Write]) where a
    caller drives assembly directly. Mirrors Go's [Decoder.Write]. *)

val close : decoder -> unit
(** [close d] is {!close_result} but {b raises} on truncated headers. Mirrors
    Go's [Decoder.Close]. *)

val decode_full : decoder -> string -> (header_field list, error) result
(** [decode_full d p] decodes the whole block [p] into a header-field list.
    Returns [Error] on a handleable decode error (invalid index, truncated
    headers, oversized string, invalid Huffman, varint overflow). Mirrors Go's
    [DecodeFull]. *)
