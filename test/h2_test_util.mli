(* Shared loopback harness for the raw-socket HTTP/2 integration suites. *)

val with_h2_raw :
  ?max_concurrent_streams:int ->
  ?max_header_bytes:int ->
  ?timeout:float ->
  handler:Httpg_http2.H2_server.handler ->
  (Eio.Buf_read.t -> Eio.Buf_write.t -> 'a) ->
  'a
(** [with_h2_raw ~handler client] runs [client r w] against an
    [H2_server.serve ~handler] over a loopback socket pair, with raw buffered
    channels, returning the client's result. The server fiber is cancelled once
    [client] returns; bounded by [?timeout] (default 15s). *)

val with_h2_server :
  ?max_concurrent_streams:int ->
  ?timeout:float ->
  handler:Httpg_http2.H2_server.handler ->
  (Httpg_http2.H2_transport.client_conn -> 'a) ->
  'a
(** [with_h2_server ~handler client] is {!with_h2_raw} with the client body
    given an established {!Httpg_http2.H2_transport.client_conn} (under its own
    switch) rather than raw channels. *)
