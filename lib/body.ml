(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser].
   [Empty] is [http.NoBody]; [String s] an in-memory body; [Stream next] a
   streaming reader yielding chunks until [next ()] returns [None] (io.EOF). *)

type t = Empty | String of string | Stream of (unit -> string option)

let empty = Empty
let of_string s = String s
let of_stream f = Stream f

let read_all (b : t) : string =
  match b with
  | Empty -> ""
  | String s -> s
  | Stream next ->
      let buf = Buffer.create 256 in
      let rec loop () =
        match next () with
        | None -> Buffer.contents buf
        | Some s ->
            Buffer.add_string buf s;
            loop ()
      in
      loop ()

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

(* Write the raw body bytes to [w] (no framing). *)
let write (w : Eio.Buf_write.t) (b : t) : unit = iter (Eio.Buf_write.string w) b
