(* Port of golang.org/x/net/http2/hpack/huffman.go (plus the [huffmanCodes]
   and [huffmanCodeLen] arrays from tables.go).

   Pure HPACK Huffman codec. No IO. *)

(** A handleable Huffman-decode error. Mirrors Go's [ErrInvalidHuffman]. *)
type error = Invalid_huffman

(** Renders {!error} as a human-readable string. *)
val error_to_string : error -> string

(** [encode s] returns the Huffman-encoded form of the bytes in [s],
    padded with the EOS prefix to a byte boundary (RFC 7541 section 5.2).
    Mirrors Go's [AppendHuffmanString] (starting from an empty buffer). *)
val encode : string -> string

(** [encoded_len s] returns the number of bytes required to encode [s] in
    Huffman codes, rounded up to a byte boundary.
    Mirrors Go's [HuffmanEncodeLength]. *)
val encoded_len : string -> int

(** [decode s] decodes the Huffman-encoded bytes in [s], validating the EOS
    padding, and returns the expanded bytes. Returns [Error Invalid_huffman]
    on invalid data (incomplete symbol, overlong padding, or non-EOS-prefix
    trailing bits). Mirrors Go's [HuffmanDecodeToString] / [huffmanDecode]. *)
val decode : string -> (string, error) result
