(* Port of go/src/net/http/sniff.go: the public net/http wrapper over the
   content-sniffing algorithm, which lives in the internal package
   (go/src/net/http/internal/sniff.go -> Httpg_internal.Sniff). *)

(* DetectContentType: returns a valid MIME type for the given data prefix,
   defaulting to "application/octet-stream". *)
let detect_content_type data = Httpg_internal.Sniff.detect_content_type data
