type t = Server.handler -> Server.handler

val chain_left : t list -> t
(** [chain_left handler middlewares] applies the middlewares in reverse order to
    [handler]. i.e. [chain_left handler [m1; m2; m3]] is equivalent to
    [m3 (m2 (m1 handler))]. *)

val apply : t -> t
(** [apply middleware handler] is equivalent to [middleware handler]. *)

val compose : t -> t -> t
(** [compose m1 m2] composes the middlewares [m1] and [m2]. such that m1 runs
    then m2. *)

val ( @ ) : t -> t -> t
(** [m1 @ m2] composes the middlewares [m1] and [m2]. such that m1 runs then m2.
*)
