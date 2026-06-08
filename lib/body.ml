(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser].
   [Empty] is [http.NoBody]; [String s] an in-memory body; [Stream next] a
   streaming reader yielding chunks until [next ()] returns [None] (io.EOF). *)

type t = Empty | String of string | Stream of (unit -> string option)

let empty = Empty
let of_string s = String s
let of_stream f = Stream f

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

let as_stream (b : t) =
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

let append_stream (s1 : stream) (s2 : stream) : stream =
  let s1_completed = ref false in
  let next () =
    if !s1_completed then s2 ()
    else
      match s1 () with
      | None ->
          s1_completed := true;
          s2 ()
      | Some s -> Some s
  in
  next

let append (b1 : t) (b2 : t) : t =
  match (b1, b2) with
  | Empty, _ -> b2
  | _, Empty -> b1
  | _, _ -> Stream (append_stream (as_stream b1) (as_stream b2))

let concat (gens : t list) : t =
  let remaining = ref gens in
  let rec next () =
    match !remaining with
    | [] -> None
    | g :: rest -> (
        match g with
        | Empty ->
            remaining := rest;
            next ()
        | String s ->
            remaining := rest;
            Some s
        | Stream st -> (
            match st () with
            | None ->
                remaining := rest;
                next ()
            | Some s -> Some s))
  in
  Stream next

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
let iter (f : string -> unit) (b : t) : unit =
  match b with
  | Empty -> ()
  | String s -> f s
  | Stream next ->
      let rec loop () =
        match next () with
        | None -> ()
        | Some s ->
            f s;
            loop ()
      in
      loop ()

let fold f (b : t) acc =
  let acc = ref acc in
  iter (fun s -> acc := f s !acc) b;
  !acc

let read_all (b : t) : string =
  let buf = Buffer.create 256 in
  let folder s buf =
    Buffer.add_string buf s;
    buf
  in
  fold folder b buf |> Buffer.contents

(* Write the raw body bytes to [w] (no framing). *)
let write (w : Eio.Buf_write.t) (b : t) : unit = iter (Eio.Buf_write.string w) b
