(* Integration tests for the public {!Server} API.

   These spin up a real loopback server on an ephemeral port (bounded by
   Test_harness.with_env so a hang fails rather than blocks) and drive it with
   the httpg [Client]. *)

open Httpg

let ok_resp = function
  | Ok resp -> resp
  | Error e -> Alcotest.failf "client: %s" (Client.error_to_string e)

let read_body b =
  match Body.read_all b with
  | Ok s -> s
  | Error e -> Alcotest.failf "body: %s" (Body.error_to_string e)

let hello_handler : Server.handler =
 fun ~sw:_ _r -> Response.create () |> Response.with_body_string "hello"

(* A server created WITHOUT [?addr] (so the internal addr field is [None] =
   "bind all interfaces", Go's empty Addr) still serves a loopback round-trip.
   We bind the ephemeral listener on 127.0.0.1 and hand it to {!Server.serve};
   the connect goes through 127.0.0.1, which an all-interfaces bind accepts. *)
let server_addr_defaults_to_all_interfaces () =
  Test_harness.with_env (fun ~net ~clock ~sw ->
      (* No [~addr]: the create knob is omitted, exercising the default path. *)
      let srv = Server.create ~net ~clock ~port:0 hello_handler in
      let listen_sock =
        match Net.listen ~sw net "127.0.0.1" 0 with
        | Ok s -> s
        | Error e -> Alcotest.failf "net listen: %s" (Net.error_to_string e)
      in
      let port =
        match Net.bound_port listen_sock with
        | Some p -> p
        | None -> Alcotest.fail "expected a bound ephemeral port"
      in
      Eio.Fiber.fork ~sw (fun () -> Server.serve srv listen_sock);
      Fun.protect
        ~finally:(fun () -> Server.close srv)
        (fun () ->
          let url = Printf.sprintf "http://127.0.0.1:%d/" port in
          let resp = ok_resp (Client.get ~sw (Client.create ~net ~clock ()) url) in
          Alcotest.(check int)
            "status 200" 200
            (Httpg_base.Status.to_int resp.Response.status);
          Alcotest.(check string) "body" "hello" (read_body resp.Response.body)))

let tests =
  [
    Alcotest.test_case "server_addr_defaults_to_all_interfaces" `Quick
      server_addr_defaults_to_all_interfaces;
  ]
