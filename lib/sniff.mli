(* Port of go/src/net/http/sniff.go and
   go/src/net/http/internal/sniff.go (DetectContentType). *)

val detect_content_type : string -> string
(** [detect_content_type data] implements the algorithm described at
    https://mimesniff.spec.whatwg.org/ to determine the MIME type of the given
    data. It considers at most the first 512 bytes and always returns a valid
    MIME type, defaulting to ["application/octet-stream"] when unknown (Go's
    [DetectContentType]). *)
