(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser].
   [Empty] is [http.NoBody]; [String s] an in-memory body; [Stream next] a
   streaming reader yielding chunks until [next ()] returns [None] (io.EOF). *)

type t = Empty | String of string | Stream of (unit -> string option)

let empty = Empty
let of_string s = String s
let of_stream f = Stream f

(* Stream an Eio source as a body, pulling up to [chunk] bytes per read until the
   source signals EOF. The source must stay open for the body's lifetime (e.g.
   opened under the consuming switch); [of_flow] does not own/close it. *)
let of_flow ?(chunk = 65536) (src : _ Eio.Flow.source) : t =
  let buf = Cstruct.create chunk in
  Stream
    (fun () ->
      match Eio.Flow.single_read src buf with
      | n -> Some (Cstruct.to_string (Cstruct.sub buf 0 n))
      | exception End_of_file -> None)

let of_lazy_string (s : string Lazy.t) : t =
  let yielded = ref false in
  Stream
    (fun () ->
      if !yielded then None
      else begin
        yielded := true;
        Some (Lazy.force s)
      end)

type stream = unit -> string option

(* Adapt a body to a pull stream [unit -> string option]: [Empty] yields [None]
   immediately, [String s] yields [s] once then [None], [Stream] is itself. *)
let to_stream (b : t) : stream =
  match b with
  | Empty -> fun () -> None
  | String s ->
      let returned = ref false in
      fun () ->
        if !returned then None
        else begin
          returned := true;
          Some s
        end
  | Stream next -> next

let of_seq (s : string Seq.t) : t =
  let s = ref s in
  Stream
    (fun () ->
      match !s () with
      | Seq.Nil -> None
      | Seq.Cons (cur, rest) ->
          s := rest;
          Some cur)

let to_seq (b : t) : string Seq.t =
  match b with
  | Empty -> Seq.empty
  | String s -> Seq.return s
  | Stream next ->
      Seq.unfold (fun next -> next () |> Option.map (fun s -> (s, next))) next

let append (b1 : t) (b2 : t) : t =
  match (b1, b2) with
  | Empty, _ -> b2
  | _, Empty -> b1
  | String s1, String s2 -> String (s1 ^ s2)
  | _, _ -> Seq.append (to_seq b1) (to_seq b2) |> of_seq

let concat (gens : t list) : t =
  List.map to_seq gens |> List.to_seq |> Seq.concat |> of_seq

(* Read and discard until EOF, or until more than [limit] bytes have been read.
   [`Drained] (within [limit]) positions a kept-alive conn at the next message
   boundary; [`Too_big] when [limit] was exceeded. Analogue of Go's bounded
   discards: finishRequest's io.CopyN (server.go) and the redirect-loop
   maxBodySlurpSize slurp (client.go). *)
let drain ?(limit : int option) (b : t) : [ `Drained | `Too_big ] =
  let over seen = match limit with Some l -> seen > l | None -> false in
  match b with
  | Empty -> `Drained
  | String s -> if over (String.length s) then `Too_big else `Drained
  | Stream next ->
      let rec loop seen =
        match next () with
        | None -> `Drained
        | Some s ->
            let seen = seen + String.length s in
            if over seen then `Too_big else loop seen
      in
      loop 0

(* Apply [f] to each successive chunk until EOF (the analogue of Go's io.Copy
   pulling from a body reader). *)
let iter (f : string -> unit) (b : t) : unit = to_seq b |> Seq.iter f
let fold_left f (b : t) acc = to_seq b |> Seq.fold_left f acc

let read_until (b : t) (max : int) : string * t option =
  let exception Stop of Buffer.t * string in
  let split s v = (String.sub s 0 v, String.sub s v (String.length s - v)) in
  let buf = Buffer.create 256 in
  let folder buf s =
    if Buffer.length buf + String.length s < max then (
      Buffer.add_string buf s;
      buf)
    else
      let prefix, remainder = split s (max - Buffer.length buf) in
      Buffer.add_string buf prefix;
      raise (Stop (buf, remainder))
  in
  try
    let buf = fold_left folder b buf in
    (Buffer.contents buf, None)
  with Stop (buf, remainder) ->
    ( Buffer.contents buf,
      if String.length remainder = 0 then None
      else Some (append (String remainder) b) )

let read_all (b : t) : string =
  let buf = Buffer.create 256 in
  let folder buf s =
    Buffer.add_string buf s;
    buf
  in
  fold_left folder b buf |> Buffer.contents

(* Write the raw body bytes to [w] (no framing). *)
let write (w : Eio.Buf_write.t) (b : t) : unit = iter (Eio.Buf_write.string w) b
