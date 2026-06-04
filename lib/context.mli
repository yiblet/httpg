(* Public re-export of {!Gohttp_base.Context}; see context.ml. The [with type t]
   constraint keeps [Gohttp.Context.t] identical to [Gohttp_base.Context.t], so
   request contexts cross the gohttp / gohttp_http2 boundary with no conversion. *)

include module type of Gohttp_base.Context with type t = Gohttp_base.Context.t
