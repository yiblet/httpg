(* Port of go/src/net/http/method.go *)

type t = string

(* Common HTTP methods.

   Unless otherwise noted, these are defined in RFC 7231 section 4.3. *)

let get = "GET"
let head = "HEAD"
let post = "POST"
let put = "PUT"
let patch = "PATCH" (* RFC 5789 *)
let delete = "DELETE"
let connect = "CONNECT"
let options = "OPTIONS"
let trace = "TRACE"
