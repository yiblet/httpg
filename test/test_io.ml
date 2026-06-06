(* Result-boundary tests for the message read/write layer (Result migration
   Ticket 5). The success-path / Go-fidelity row tests live in
   test_readrequest.ml / test_response.ml / test_requestwrite.ml (which use the
   [*_exn] shims); this suite exercises the typed [Io.error] boundary directly.

   Bounded by Net.with_timeout so a hang fails instead of blocking. *)

open Httpg

let ic_of_string s = Lwt_io.of_bytes ~mode:Lwt_io.input (Lwt_bytes.of_string s)

(* A null output channel: discards everything written. *)
let null_oc () =
  Lwt_io.make ~mode:Lwt_io.output (fun _bytes _off len -> Lwt.return len)

let req_no_host () : Body.t Request.t =
  {
    Request.meth = "GET";
    url = Uri.of_string "/just/a/path";
    proto = "HTTP/1.1";
    proto_major = 1;
    proto_minor = 1;
    header = Header.create ();
    body = Body.Empty;
    content_length = 0L;
    transfer_encoding = [];
    close = false;
    host = "";
    trailer = None;
    request_uri = "";
    remote_addr = "";
    form = None;
    post_form = None;
    multipart_form = None;
    ctx = Context.background;
  }

(* read_request: malformed request line and a bad header line both surface as
   Error (Protocol _); a well-formed request -> Ok; write_request with no Host
   -> Error Missing_host. *)
let read_request_malformed () =
  Lwt_main.run
    (Net.with_timeout 5.0
       (let open Lwt.Infix in
        (* (a) malformed request line: no method/uri/proto split. *)
        Io.read_request (ic_of_string "GET\r\n\r\n") >>= fun res_a ->
        (match res_a with
        | Error (Io.Protocol _) ->
            Alcotest.(check pass) "malformed request line -> Protocol" () ()
        | Error e ->
            Alcotest.failf "malformed line -> Error %s; want Protocol _"
              (Io.error_to_string e)
        | Ok _ -> Alcotest.fail "malformed request line -> Ok; want Error");
        (* (b) bad header line (no colon). *)
        Io.read_request (ic_of_string "GET / HTTP/1.1\r\nbadheader\r\n\r\n")
        >>= fun res_b ->
        (match res_b with
        | Error (Io.Protocol _) ->
            Alcotest.(check pass) "bad header line -> Protocol" () ()
        | Error e ->
            Alcotest.failf "bad header -> Error %s; want Protocol _"
              (Io.error_to_string e)
        | Ok _ -> Alcotest.fail "bad header line -> Ok; want Error");
        (* (c) well-formed request -> Ok. *)
        Io.read_request (ic_of_string "GET / HTTP/1.1\r\nHost: foo.com\r\n\r\n")
        >>= fun res_c ->
        (match res_c with
        | Ok r ->
            Alcotest.(check string) "method" "GET" r.Request.meth;
            Alcotest.(check string) "host" "foo.com" r.Request.host
        | Error e ->
            Alcotest.failf "well-formed request -> Error %s; want Ok"
              (Io.error_to_string e));
        (* (d) write_request with no Host -> Error Missing_host. *)
        let oc = null_oc () in
        Io.write_request oc (req_no_host ()) >>= fun res_d ->
        (match res_d with
        | Error Io.Missing_host ->
            Alcotest.(check pass) "no host -> Missing_host" () ()
        | Error e ->
            Alcotest.failf "no host -> Error %s; want Missing_host"
              (Io.error_to_string e)
        | Ok () -> Alcotest.fail "no host write -> Ok; want Error Missing_host");
        Lwt.return_unit))

let tests = [ ("read_request_malformed", `Quick, read_request_malformed) ]
