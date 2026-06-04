(* Port of go/src/net/http/internal/sniff.go. The content-sniffing algorithm
   lives here (package [internal] in Go) so it can be shared without importing
   the public request/response types; lib/sniff.ml is the public wrapper. *)

(* The algorithm uses at most this many bytes to make its decision
   (Go's [SniffLen]). *)
val sniff_len : int

(* [detect_content_type data] implements the algorithm described at
   https://mimesniff.spec.whatwg.org/ to determine the MIME type of the given
   data. It considers at most the first [sniff_len] bytes and always returns a
   valid MIME type, defaulting to ["application/octet-stream"] when unknown
   (Go's [internal.DetectContentType]). *)
val detect_content_type : string -> string
