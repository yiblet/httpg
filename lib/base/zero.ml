module type ZeroType = sig
  type t

  val zero : t
  val compare : t -> t -> int
end

module Make (V : ZeroType) = struct
  (* Canonical form invariant: a value is either [None] (the zero value) or
     [Some v] with [v <> V.zero]. [of_zero] is the only constructor and the
     only place that establishes it; everything else routes through [of_zero]
     or [fold], so [Some V.zero] can never exist and the comparisons below
     agree with Go's [==] by construction. *)
  type t = V.t option

  let zero = None
  let of_zero v = if V.compare v V.zero = 0 then None else Some v
  let v_is_set v = V.compare v V.zero <> 0

  let fold ~set ~zero x =
    match x with Some v when v_is_set v -> set v | _ -> zero

  let to_zero x = fold ~set:Fun.id ~zero:V.zero x
  let is_zero = fold ~set:(fun _ -> false) ~zero:true
  let is_set x = fold ~set:(fun _ -> true) ~zero:false x
  let compare a b = V.compare (to_zero a) (to_zero b)
  let equal a b = compare a b = 0
  let check f x = fold ~set:f ~zero:false x
  let iter g x = fold ~set:g ~zero:() x
  let map f x = fold ~set:(fun v -> of_zero (f v)) ~zero:None x

  let filter f x =
    fold ~set:(fun v -> if f v then of_zero v else None) ~zero:None x
end

module String = Make (struct
  include String

  let zero = ""
end)

module Int = Make (Int)
