(** Typed zero values.

    Go conflates "absent/unset" with a type's zero value ([""], [0], …): a field
    left at its zero value reads identically to one explicitly set to it.
    Porting that faithfully but safely means a type that {e behaves} like the Go
    scalar — same operations, same comparisons — while making the conflation
    explicit and impossible to break by hand.

    [Make] produces such a type for any zero-equipped scalar. It is {b abstract}
    and [of_zero] is the {b only} constructor, normalizing [V.zero] to the zero
    case, so [Some V.zero] can never exist and {!is_zero}/{!equal}/{!compare}
    always agree with Go's [==]. Every Go idiom on a zero-able field maps to
    exactly one operation here, so the translation is mechanical:

    {v
      Go                                OCaml
      "" / 0                            zero
      x = v                             of_zero v
      f(x), x[i], real len(x)           to_zero x
      x == "" / len(x) == 0             is_zero x
      x != "" / len(x) > 0              is_set x
      a == b                            equal a b
      sort / <                          compare a b
      x != "" && f(x)                   check f x
      if x != "" { g(x) }               iter g x
      x = if f(x) then x else ""        filter f x
      if x != "" { e1 } else { e2 }     fold ~zero:e2 ~set:(fun v -> e1) x
    v}

    [of_zero] and [fold] are the only primitives; everything else is derived
    through them, so the canonical-form invariant lives in one place. *)

module type ZeroType = sig
  type t

  val zero : t
  val compare : t -> t -> int
end

module Make (V : ZeroType) : sig
  type t = V.t Option.t
  (** A canonical zero-or-value. Either the zero value or some [v <> V.zero]; no
      other state is representable. *)

  val zero : t
  (** The zero value (Go's [""], [0], …). *)

  val of_zero : V.t -> t
  (** The only constructor. Normalizes [V.zero] to {!zero}. *)

  val to_zero : t -> V.t
  (** Read as the underlying Go value ([zero] yields [V.zero]). *)

  val is_zero : t -> bool
  (** Go's [x == ""] / [len x == 0]. *)

  val is_set : t -> bool
  (** Go's [x != ""] / [len x > 0]. *)

  val equal : t -> t -> bool
  (** Go's [a == b]. *)

  val compare : t -> t -> int
  (** Total order; the zero value sorts as [V.zero] would. *)

  val check : (V.t -> bool) -> t -> bool
  (** Go's [x != "" && f x]: [false] on {!zero}, else [f] applied. *)

  val iter : (V.t -> unit) -> t -> unit
  (** Go's [if x != "" { g x }]. *)

  val map : (V.t -> V.t) -> t -> t
  (** Map the set case, re-normalizing the result (a mapped value that lands on
      [V.zero] collapses to {!zero}). *)

  val filter : (V.t -> bool) -> t -> t
  (** Demote to {!zero} when [f] fails; {!zero} stays {!zero}. Go's
      [x = if f x then x else ""]. *)

  val fold : set:(V.t -> 'a) -> zero:'a -> t -> 'a
  (** The eliminator. Go's [if x != "" { set x } else { zero }]. Any elimination
      of a zero-able value can be expressed through it without exposing the
      representation. *)
end

module String : sig
  include module type of Make (struct
    type t = string

    let zero = ""
    let compare = String.compare
  end)
end

module Int : sig
  include module type of Make (struct
    type t = int

    let zero = 0
    let compare = Int.compare
  end)
end
