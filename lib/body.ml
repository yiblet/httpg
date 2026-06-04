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

(* Read and discard the whole body until EOF. [Empty]/[String] are no-ops
   (nothing is held on the wire). For a [Stream] this pulls every chunk until
   [next ()] returns [None], the analogue of Go's body.Close consuming to EOF
   so a kept-alive connection is positioned at the next message boundary. *)
let drain (b : t) : unit Lwt.t =
  match b with
  | Empty | String _ -> Lwt.return_unit
  | Stream next ->
      let rec loop () =
        Lwt.bind (next ()) (fun chunk ->
            match chunk with None -> Lwt.return_unit | Some _ -> loop ())
      in
      loop ()

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
