(* Port of golang.org/x/net/http2/hpack/huffman.go (plus the [huffmanCodes]
   and [huffmanCodeLen] arrays from tables.go).

   Pure HPACK Huffman codec. No IO. *)

(** A handleable Huffman-decode error. [Invalid_huffman] mirrors Go's
    [ErrInvalidHuffman]; [String_too_long] mirrors Go's [ErrStringLength]
    (raised when the decoded output would exceed the configured maximum). *)
type error = Invalid_huffman | String_too_long

val error_to_string : error -> string
(** Renders {!error} as a human-readable string. *)

val encode : string -> string
(** [encode s] returns the Huffman-encoded form of the bytes in [s], padded with
    the EOS prefix to a byte boundary (RFC 7541 section 5.2). Mirrors Go's
    [AppendHuffmanString] (starting from an empty buffer). *)

val encoded_len : string -> int
(** [encoded_len s] returns the number of bytes required to encode [s] in
    Huffman codes, rounded up to a byte boundary. Mirrors Go's
    [HuffmanEncodeLength]. *)

val decode : ?max_len:int -> string -> (string, error) result
(** [decode ?max_len s] decodes the Huffman-encoded bytes in [s], validating the
    EOS padding, and returns the expanded bytes. Returns [Error Invalid_huffman]
    on invalid data (incomplete symbol, overlong padding, or non-EOS-prefix
    trailing bits). When [max_len > 0], decoding stops with
    [Error String_too_long] the moment the output would exceed [max_len] bytes,
    bounding the transient allocation (default [0] = unlimited). Mirrors Go's
    [HuffmanDecodeToString] / [huffmanDecode]. *)
