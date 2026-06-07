(* Port of go/src/net/http/method.go *)

type t =
  | Get
  | Head
  | Post
  | Put
  | Patch (* RFC 5789 *)
  | Delete
  | Connect
  | Options
  | Trace
  | Custom of string

let to_string = function
  | Get -> "GET"
  | Head -> "HEAD"
  | Post -> "POST"
  | Put -> "PUT"
  | Patch -> "PATCH"
  | Delete -> "DELETE"
  | Connect -> "CONNECT"
  | Options -> "OPTIONS"
  | Trace -> "TRACE"
  | Custom s -> s

let of_string = function
  | "GET" -> Get
  | "HEAD" -> Head
  | "POST" -> Post
  | "PUT" -> Put
  | "PATCH" -> Patch
  | "DELETE" -> Delete
  | "CONNECT" -> Connect
  | "OPTIONS" -> Options
  | "TRACE" -> Trace
  | s -> Custom s

(* Common HTTP methods, aliases of the variant constructors. *)
let get = Get
let head = Head
let post = Post
let put = Put
let patch = Patch (* RFC 5789 *)
let delete = Delete
let connect = Connect
let options = Options
let trace = Trace
