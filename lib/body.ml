(* A concrete HTTP message body, the analogue of Go's [io.ReadCloser], modeled
   as a lazy sequence of result-typed chunks: [(string, error) result Seq.t].
   Each forced element is [Ok chunk] (more data) or a terminal [Error e] (a
   mid-stream framing failure). Mid-stream failure is data — the [Error]
   element — never a raise from inside a pull thunk.

   The old [Empty | String | Stream] distinction is gone: an empty body is
   [Seq.empty], an in-memory body is a single-element [Ok] seq, a streaming body
   is a lazy seq. The "known length vs streaming" framing decision now lives in
   the [content_length] field on Request/Response, not in the body shape. *)

(* Mid-stream framing failure. Body sits BELOW Transfer/Io (layering), so it
   cannot name [Transfer.error]/[Io.error]; those modules map INTO this variant
   when they build a streaming body (see [Io.stream_body]). The text mirrors
   Go's messages for the wire/log analogue. *)
type error =
  | Malformed_chunk of string  (** malformed chunked framing (Go's message) *)
  | Line_too_long
      (** chunk line exceeded the limit (internal.ErrLineTooLong) *)
  | Trailer_too_large  (** suspiciously long trailer after a chunked body *)
  | Unexpected_eof  (** stream ended before the declared length *)
  | Protocol of string  (** other mid-stream protocol failure (message text) *)

let error_to_string = function
  | Malformed_chunk msg -> msg
  | Line_too_long -> "http: chunk line too long"
  | Trailer_too_large -> "http: suspiciously long trailer after chunked body"
  | Unexpected_eof -> "unexpected EOF"
  | Protocol s -> s

type t = { size : int64 option; content : (string, error) result Seq.t }

(* [Seq.unfold] over a stateful [next] thunk re-invokes the thunk on every force
   of a node, so forcing the same node twice would advance the generator and
   yield different results. [Seq.memoize] makes force idempotent: each node
   caches its forced value, so a body is a persistent, replayable sequence. *)
let unfold_memoized f s = Seq.unfold f s |> Seq.memoize

(* A zero-length body: its length is known (0), the analogue of Go's [NoBody]
   whose [ContentLength] is 0. *)
let empty : t = { size = Some 0L; content = Seq.empty }

let of_string s : t =
  if s = "" then empty
  else
    {
      size = Some (Int64.of_int (String.length s));
      content = Seq.return (Ok s);
    }

let of_seq (s : _ Seq.t) : t = { size = None; content = s }
let to_seq (b : t) = b.content

let of_string_seq (s : string Seq.t) : t =
  { size = None; content = s |> Seq.map Result.ok }

let content_length (b : t) = b.size

(* Build a streaming body from a pull thunk yielding successive chunks until
   [None] (io.EOF). The thunk must NOT raise a framing error: this constructor
   emits only [Ok] chunks. (The read paths that wrap a raising thunk use
   {!of_stream_result}, which carries the [Error] terminal explicitly.) *)
let of_stream (next : unit -> string option) : t =
  unfold_memoized (fun () -> next () |> Option.map (fun s -> (Ok s, ()))) ()
  |> of_seq

(* Build a streaming body from a pull thunk yielding [(string, error) result]:
   [Some (Ok s)] is a chunk, [Some (Error e)] is the terminal failure (the seq
   ends after it), [None] is clean EOF. This is the adapter the read paths use
   to surface a mid-stream framing failure as a terminal [Error] element rather
   than a raise. *)
let of_stream_result (next : unit -> (string, error) result option) : t =
  unfold_memoized
    (fun stopped ->
      if stopped then None
      else
        match next () with
        | None -> None
        | Some (Ok _ as c) -> Some (c, false)
        | Some (Error _ as e) -> Some (e, true))
    false
  |> of_seq

(* Stream an Eio source as a body, pulling up to [chunk] bytes per read until the
   source signals EOF. The source must stay open for the body's lifetime (e.g.
   opened under the consuming switch); [of_flow] does not own/close it. *)
let of_flow ?(chunk = 65536) (src : _ Eio.Flow.source) : t =
  let buf = Cstruct.create chunk in
  of_stream (fun () ->
      match Eio.Flow.single_read src buf with
      | n -> Some (Cstruct.to_string (Cstruct.sub buf 0 n))
      | exception End_of_file -> None)

let of_lazy_string (s : string Lazy.t) : t =
  let yielded = ref false in
  of_stream (fun () ->
      if !yielded then None
      else begin
        yielded := true;
        Some (Lazy.force s)
      end)

type stream = unit -> (string, error) result option

let option_both (o1 : 'a option) (o2 : 'b option) : ('a * 'b) option =
  match (o1, o2) with
  | Some a, Some b -> Some (a, b)
  | None, None -> None
  | _ -> None

(* Adapt a body to a pull stream [unit -> (string, error) result option]: each
   call forces the next element ([None] at EOF). The dual of {!of_stream_result}. *)
let to_stream (b : t) : stream =
  let s = ref b.content in
  fun () ->
    match !s () with
    | Seq.Nil -> None
    | Seq.Cons (x, rest) ->
        s := rest;
        Some x

let append (b1 : t) (b2 : t) : t =
  let size =
    option_both b1.size b2.size |> Option.map (fun (a, b) -> Int64.add a b)
  in
  { size; content = Seq.append b1.content b2.content }

let concat (gens : t list) : t =
  let exception Stop in
  let size =
    match
      List.fold_left
        (fun acc b ->
          match b.size with Some s -> Int64.add acc s | None -> raise Stop)
        0L gens
    with
    | exception Stop -> None
    | s -> Some s
  in
  {
    size;
    content = List.to_seq gens |> Seq.map (fun b -> b.content) |> Seq.concat;
  }

(* Run [f] once when the body is read to EOF, preserving the size hint. The
   chunks pass through unchanged; [f] fires the first time the underlying seq
   yields [Nil] (clean EOF). A mid-stream [Error] terminates the seq without
   reaching [Nil], so [f] does NOT run on failure — the analogue of Go releasing
   a connection only after a clean body read. [f] runs at most once per forced
   traversal; [Seq.memoize] makes re-traversal of the cached nodes free, so the
   [Nil] node (and thus [f]) is reached again only by re-forcing past the tail. *)
let on_complete (b : t) (f : unit -> unit) : t =
  let rec wrap seq () =
    match seq () with
    | Seq.Nil ->
        f ();
        Seq.Nil
    | Seq.Cons (x, rest) -> Seq.Cons (x, wrap rest)
  in
  { b with content = wrap b.content }

(* Peek the first element, returning it (or [None] at EOF) together with a body
   that re-reads it in full (the forced prefix is memoized via [Seq.cons], so
   the result is non-destructive). Forces exactly one element — use only where a
   single forced look-ahead is acceptable (the write-side framing probe, where
   the body is about to be written immediately). *)
let peek (b : t) : (string, error) Stdlib.result option * t =
  match b.content () with Seq.Nil -> (None, b) | Seq.Cons (x, _) -> (Some x, b)

(* Whether the body has no content (the analogue of Go's [Body == nil]): forces
   one element. A non-destructive peek — the returned body re-reads in full. *)
let is_empty (b : t) : bool * t =
  match peek b with None, b -> (true, b) | Some _, b -> (false, b)

(* Fold [f] over each successive [Ok] chunk in order, short-circuiting at the
   first [Error] element (returned as [Error e]). The shared engine behind
   {!iter}/{!fold_left}/{!read_all}/{!drain}. *)
let fold_left (f : 'a -> string -> 'a) (b : t) (acc : 'a) :
    ('a, error) Stdlib.result =
  let exception Failed of error in
  let step acc = function Ok s -> f acc s | Error e -> raise (Failed e) in
  match Seq.fold_left step acc b.content with
  | acc -> Ok acc
  | exception Failed e -> Error e

let iter (f : string -> unit) (b : t) : (unit, error) Stdlib.result =
  fold_left (fun () s -> f s) b ()

(* Read and discard until EOF, or until more than [limit] bytes have been read.
   [`Drained] (within [limit]) positions a kept-alive conn at the next message
   boundary; [`Too_big] when [limit] was exceeded; [Error] on a mid-stream
   framing failure. Analogue of Go's bounded discards: finishRequest's io.CopyN
   (server.go) and the redirect-loop maxBodySlurpSize slurp (client.go). *)
let drain ?(limit : int option) (b : t) :
    ([ `Drained | `Too_big ], error) Stdlib.result =
  let over seen = match limit with Some l -> seen > l | None -> false in
  let exception Too_big in
  let exception Failed of error in
  let step seen = function
    | Ok s ->
        let seen = seen + String.length s in
        if over seen then raise Too_big else seen
    | Error e -> raise (Failed e)
  in
  match Seq.fold_left step 0 b.content with
  | _ -> Ok `Drained
  | exception Too_big -> Ok `Too_big
  | exception Failed e -> Error e

let read_all (b : t) : (string, error) Stdlib.result =
  let buf = Buffer.create 256 in
  match
    fold_left
      (fun () s ->
        Buffer.add_string buf s;
        ())
      b ()
  with
  | Ok () -> Ok (Buffer.contents buf)
  | Error e -> Error e

(* [read_until b max] reads up to [max] bytes. The first string is the read
   bytes; the second is the remainder of the body (if any). Short-circuits on a
   mid-stream [Error]. *)
let read_until (b : t) (max : int) : (string * t option, error) Stdlib.result =
  let split s v = (String.sub s 0 v, String.sub s v (String.length s - v)) in
  let original_size = b.size in
  let buf = Buffer.create 256 in
  (* Pull elements until we hit [max], EOF, or an [Error]. *)
  let rec loop (s : (string, error) Result.t Seq.t) :
      (string * t option, error) Stdlib.result =
    match s () with
    | Seq.Nil -> Ok (Buffer.contents buf, None)
    | Seq.Cons (Error e, _) -> Error e
    | Seq.Cons (Ok chunk, rest) ->
        if Buffer.length buf + String.length chunk < max then begin
          Buffer.add_string buf chunk;
          loop rest
        end
        else begin
          let prefix, remainder = split chunk (max - Buffer.length buf) in
          Buffer.add_string buf prefix;
          let res = Buffer.contents buf in
          (* Match the original: the remainder body is offered iff bytes were
             split off this chunk; we never force [rest] to peek further. *)
          let new_size =
            match original_size with
            | Some s -> Some (Int64.sub s (Int64.of_int (String.length res)))
            | None -> None
          in
          Ok
            ( res,
              if String.length remainder = 0 then None
              else
                Some { size = new_size; content = Seq.cons (Ok remainder) rest }
            )
        end
  in
  loop b.content

(* Write the raw body bytes to [w] (no framing). Short-circuits on a mid-stream
   [Error]. *)
let write (w : Eio.Buf_write.t) (b : t) : (unit, error) Stdlib.result =
  iter (Eio.Buf_write.string w) b
