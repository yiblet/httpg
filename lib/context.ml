(* Re-export of the foundation [Httpg_base.Context] (port of Go's stdlib
   [context] package) as the public [Httpg.Context]. The implementation lives
   in the httpg_base library so the HTTP/2 stack (httpg_http2) can depend on it
   without depending on the public httpg library. *)

include Httpg_base.Context
