(* Re-export of the foundation [Gohttp_base.Context] (port of Go's stdlib
   [context] package) as the public [Gohttp.Context]. The implementation lives
   in the gohttp_base library so the HTTP/2 stack (gohttp_http2) can depend on it
   without depending on the public gohttp library. *)

include Gohttp_base.Context
