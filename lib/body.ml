(* A concrete HTTP message body over Lwt.

   Go models a body as an [io.ReadCloser] (an interface). Here we use a concrete
   variant: an in-memory string, or a streaming reader yielding chunks until it
   returns [None] (the analogue of [io.EOF]). [Empty] is the analogue of
   [http.NoBody]. *)

type t = Empty | String of string | Stream of (unit -> string option Lwt.t)

let empty = Empty
let of_string s = String s
let of_stream f = Stream f

(* Read the whole body into a single string. *)
let read_all (b : t) : string Lwt.t =
  match b with
  | Empty -> Lwt.return ""
  | String s -> Lwt.return s
  | Stream next ->
      let buf = Buffer.create 256 in
      let rec loop () =
        Lwt.bind (next ()) (fun chunk ->
            match chunk with
            | None -> Lwt.return (Buffer.contents buf)
            | Some s ->
                Buffer.add_string buf s;
                loop ())
      in
      loop ()

(* Read and discard the body until EOF, or until more than [limit] bytes have
   been read. Returns [`Drained] if the body reached EOF (within [limit] when
   given) — a kept-alive connection is then positioned at the next message
   boundary — or [`Too_big] if [limit] was given and more bytes remained unread.
   With no [limit] the whole body is consumed (always [`Drained]), the analogue
   of Go's [io.Copy(io.Discard, body)]. With [limit] it is the analogue of the
   bounded discards Go uses to keep a connection alive: [finishRequest]'s
   [io.CopyN(io.Discard, body, maxPostHandlerReadBytes+1)] (server.go) and the
   redirect loop's [maxBodySlurpSize] slurp (client.go); past the bound the
   caller closes the connection instead of reading an unbounded amount.
   [Empty]/[String] are no-ops unless they themselves exceed [limit]. *)
let drain ?(limit : int option) (b : t) : [ `Drained | `Too_big ] Lwt.t =
  let over seen = match limit with Some l -> seen > l | None -> false in
  match b with
  | Empty -> Lwt.return `Drained
  | String s ->
      Lwt.return (if over (String.length s) then `Too_big else `Drained)
  | Stream next ->
      let rec loop seen =
        Lwt.bind (next ()) (fun chunk ->
            match chunk with
            | None -> Lwt.return `Drained
            | Some s ->
                let seen = seen + String.length s in
                if over seen then Lwt.return `Too_big else loop seen)
      in
      loop 0

(* Apply [f] to each successive chunk of the body, in order, until EOF.
   [Empty] yields no calls; [String s] yields exactly one call [f s]; a
   [Stream] yields one call per chunk pulled until [next ()] returns [None].
   Used by streaming writers (the analogue of Go's [io.Copy] pulling from a
   body reader). *)
let iter (f : string -> unit Lwt.t) (b : t) : unit Lwt.t =
  match b with
  | Empty -> Lwt.return_unit
  | String s -> f s
  | Stream next ->
      let rec loop () =
        Lwt.bind (next ()) (fun chunk ->
            match chunk with
            | None -> Lwt.return_unit
            | Some s -> Lwt.bind (f s) loop)
      in
      loop ()

(* Write the raw body bytes to [oc] (no framing). *)
let write (oc : Lwt_io.output_channel) (b : t) : unit Lwt.t =
  match b with
  | Empty -> Lwt.return_unit
  | String s -> Lwt_io.write oc s
  | Stream next ->
      let rec loop () =
        Lwt.bind (next ()) (fun chunk ->
            match chunk with
            | None -> Lwt.return_unit
            | Some s -> Lwt.bind (Lwt_io.write oc s) loop)
      in
      loop ()
