type t = Server.handler -> Server.handler

let chain_left middlewares handler =
  List.fold_left (fun h m -> m h) handler middlewares

let apply middleware handler = middleware handler
let compose m1 m2 h = m2 (m1 h)
let ( @ ) = compose
