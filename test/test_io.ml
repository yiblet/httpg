(* Result-boundary tests for the message read/write layer. The success-path /
   Go-fidelity row tests live in test_readrequest.ml / test_response.ml /
   test_requestwrite.ml; this suite exercises the typed [Io.error] boundary. *)

open Httpg

let r_of_string = Eio.Buf_read.of_string

let req_no_host () : Request.t =
  {
    Request.meth = Httpg_base.Method.Get;
    url = Uri.of_string "/just/a/path";
    proto = Httpg_base.Protocol.Http11;
    header = Header.create ();
    body = Body.empty;
    content_length = Some 0L;
    transfer_encoding = [];
    close = false;
    host = None;
    trailer = None;
    request_uri = None;
    remote_addr = None;
  }

(* read_request: malformed request line and a bad header line both surface as
   Error (Protocol _); a well-formed request -> Ok; write_request with no Host
   -> Error Missing_host. *)
let read_request_malformed () =
  (* (a) malformed request line: no method/uri/proto split. *)
  (match Io.read_request (r_of_string "GET\r\n\r\n") with
  | Error (Io.Protocol _) ->
      Alcotest.(check pass) "malformed request line -> Protocol" () ()
  | Error e ->
      Alcotest.failf "malformed line -> Error %s; want Protocol _"
        (Io.error_to_string e)
  | Ok _ -> Alcotest.fail "malformed request line -> Ok; want Error");
  (* (b) bad header line (no colon). *)
  (match
     Io.read_request (r_of_string "GET / HTTP/1.1\r\nbadheader\r\n\r\n")
   with
  | Error (Io.Protocol _) ->
      Alcotest.(check pass) "bad header line -> Protocol" () ()
  | Error e ->
      Alcotest.failf "bad header -> Error %s; want Protocol _"
        (Io.error_to_string e)
  | Ok _ -> Alcotest.fail "bad header line -> Ok; want Error");
  (* (c) well-formed request -> Ok. *)
  (match
     Io.read_request (r_of_string "GET / HTTP/1.1\r\nHost: foo.com\r\n\r\n")
   with
  | Ok r ->
      Alcotest.(check string)
        "method" "GET"
        (Httpg_base.Method.to_string r.Request.meth);
      Alcotest.(check string)
        "host" "foo.com"
        (Option.value ~default:"" r.Request.host)
  | Error e ->
      Alcotest.failf "well-formed request -> Error %s; want Ok"
        (Io.error_to_string e));
  (* (d) write_request with no Host -> Error Missing_host. *)
  let w = Eio.Buf_write.create 256 in
  match Io.write_request w (req_no_host ()) with
  | Error Io.Missing_host ->
      Alcotest.(check pass) "no host -> Missing_host" () ()
  | Error e ->
      Alcotest.failf "no host -> Error %s; want Missing_host"
        (Io.error_to_string e)
  | Ok () -> Alcotest.fail "no host write -> Ok; want Error Missing_host"

let tests = [ ("read_request_malformed", `Quick, read_request_malformed) ]
