(* Public re-export of {!Httpg_base.Context}; see context.ml. The [with type t]
   constraint keeps [Httpg.Context.t] identical to [Httpg_base.Context.t], so
   request contexts cross the httpg / httpg_http2 boundary with no conversion. *)

include module type of Httpg_base.Context with type t = Httpg_base.Context.t
