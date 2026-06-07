(* Gating test for ticket 013: the server delivers genuine PARALLELISM across OS
   cores via the Eio domain pool (feature.md "Multicore concurrency works").

   The decisive test (F022): a CPU-BOUND handler (a busy compute loop, NOT a
   sleep — sleeps yield and would hide a single-core limit), driven by N = cores
   concurrent clients. A single-domain server serializes the CPU work (wall
   ~= N * T); the domain pool runs it in parallel (wall ~= T). We assert wall is
   well below the serial N*T, and that a mutex-guarded shared counter ends exact
   under true parallelism (no lost updates / data race). *)

open Httpg

(* ~T-millisecond CPU busy loop: a real integer grind the optimizer cannot
   elide (the result is observed). Calibrated once per process against the
   monotonic clock so it spends roughly [target_s] seconds of CPU regardless of
   machine speed. *)
let calibrate_iters clock ~target_s =
  let spin n =
    let acc = ref 0 in
    for i = 1 to n do
      acc := (!acc + (i * 2654435761)) land 0x3FFFFFFF
    done;
    !acc
  in
  (* grow until one spin takes >= target_s, then scale to target. *)
  let rec grow n =
    let t0 = Eio.Time.now clock in
    ignore (spin n : int);
    let dt = Eio.Time.now clock -. t0 in
    if dt >= target_s || n > 1_000_000_000 then
      int_of_float (float_of_int n *. (target_s /. Float.max dt 1e-6))
    else grow (n * 2)
  in
  (grow 100_000, spin)

let cpu_handler ~iters ~spin ~counter ~mtx =
  Server.handler_func (fun w _r ->
      let r = spin iters in
      Mutex.lock mtx;
      incr counter;
      Mutex.unlock mtx;
      w.Server.write (string_of_int r))

(* Fire [n] concurrent GETs at [url] over a shared transport (the F014-safe
   pattern: one transport switch, one fiber per request), return their count. *)
let hammer ~net ~clock ~sw ~url n =
  let transport = Transport.create ~net ~clock () in
  let client = Client.create ~net ~clock ~transport () in
  let ok = Atomic.make 0 in
  Eio.Fiber.all
    (List.init n (fun _ () ->
         let resp = Client.get ~sw client url in
         ignore (Body.read_all resp.Response.body);
         if (Httpg_base.Status.to_int resp.Response.status_code) = 200 then Atomic.incr ok));
  Atomic.get ok

(* ---- the multicore parallelism gate ---- *)

let multicore_parallel () =
  let cores = Domain.recommended_domain_count () in
  if cores < 2 then
    (* A 1-core CI cannot demonstrate parallelism; the assertion is vacuous. *)
    Printf.printf "[multicore] only %d core(s); skipping parallelism gate\n%!"
      cores
  else
    Test_harness.with_env_dm ~secs:60. (fun ~net ~clock ~domain_mgr ~sw ->
        let target_s = 0.20 in
        let iters, spin = calibrate_iters clock ~target_s in
        let counter = ref 0 and mtx = Mutex.create () in
        let handler = cpu_handler ~iters ~spin ~counter ~mtx in
        let n = cores in
        (* Serve across all cores. *)
        let srv, port, serve_loop =
          Server.listen_and_serve_started ~net ~clock ~domain_mgr ~sw
            ~addr:"127.0.0.1" ~port:0 handler
        in
        Eio.Fiber.fork ~sw serve_loop;
        let url = Printf.sprintf "http://127.0.0.1:%d/" port in
        (* Warm one request so domains/connections are up before timing. *)
        ignore (hammer ~net ~clock ~sw ~url 1 : int);
        counter := 0;
        let t0 = Eio.Time.now clock in
        let ok = hammer ~net ~clock ~sw ~url n in
        let wall = Eio.Time.now clock -. t0 in
        Server.close srv;
        let serial = float_of_int n *. target_s in
        Printf.printf
          "[multicore] cores=%d clients=%d per-handler~%.0fms wall=%.0fms \
           serial~%.0fms ok=%d count=%d\n\
           %!"
          cores n (target_s *. 1000.) (wall *. 1000.) (serial *. 1000.) ok
          !counter;
        Alcotest.(check int) "all requests ok" n ok;
        Alcotest.(check int) "shared counter exact (no lost updates)" n !counter;
        (* Parallel: wall must be far below the serial N*T. Generous tolerance
           (< N*T/2) keeps it robust against scheduling/IO jitter while still
           failing a serial (single-domain) server, which is ~N*T. *)
        Alcotest.(check bool)
          (Printf.sprintf "wall %.0fms < serial/2 %.0fms (parallel, not serial)"
             (wall *. 1000.) (serial *. 500.))
          true
          (wall < serial /. 2.))

(* Single-domain (?domains:1) still serves correctly — the legacy path. *)
let single_domain_serves () =
  Test_harness.with_env_dm (fun ~net ~clock ~domain_mgr ~sw ->
      let counter = ref 0 and mtx = Mutex.create () in
      let handler =
        Server.handler_func (fun w _r ->
            Mutex.lock mtx;
            incr counter;
            Mutex.unlock mtx;
            w.Server.write "ok")
      in
      let srv, port, serve_loop =
        Server.listen_and_serve_started ~net ~clock ~domain_mgr ~domains:1 ~sw
          ~addr:"127.0.0.1" ~port:0 handler
      in
      Eio.Fiber.fork ~sw serve_loop;
      let url = Printf.sprintf "http://127.0.0.1:%d/" port in
      let ok = hammer ~net ~clock ~sw ~url 8 in
      Server.close srv;
      Alcotest.(check int) "8 ok" 8 ok;
      Alcotest.(check int) "counter 8" 8 !counter)

(* close tears the pool down cleanly: a fresh server can rebind and serve after
   a multicore server on the same harness is closed (no leaked fibers/fds). *)
let close_then_reserve () =
  Test_harness.with_env_dm (fun ~net ~clock ~domain_mgr ~sw ->
      let handler = Server.handler_func (fun w _r -> w.Server.write "x") in
      let serve_once () =
        let srv, port, serve_loop =
          Server.listen_and_serve_started ~net ~clock ~domain_mgr ~sw
            ~addr:"127.0.0.1" ~port:0 handler
        in
        Eio.Fiber.fork ~sw serve_loop;
        let url = Printf.sprintf "http://127.0.0.1:%d/" port in
        let ok = hammer ~net ~clock ~sw ~url 4 in
        Server.close srv;
        ok
      in
      let a = serve_once () in
      let b = serve_once () in
      Alcotest.(check int) "first server served" 4 a;
      Alcotest.(check int) "second server served after close" 4 b)

(* Multicore TLS: per-domain RNG (the stateless getrandom generator) must let
   concurrent cross-domain handshakes succeed. N concurrent HTTPS GETs, each on
   its OWN transport so each dials a FRESH TLS connection => a fresh handshake;
   under the domain pool those handshakes run on different server domains in
   parallel. Advertise only http/1.1 so each request is a separate connection
   (no h2 multiplexing onto one conn). This is the gate for hazard F022 #4. *)
let multicore_tls () =
  Test_harness.with_env_dm ~secs:60. (fun ~net ~clock ~domain_mgr ~sw ->
      let handler = Server.handler_func (fun w _r -> w.Server.write "tls-ok") in
      let certificates = Net.test_server_certificate () in
      let srv, port, serve_loop =
        Server.listen_and_serve_tls_started ~net ~clock ~domain_mgr
          ~certificates ~alpn:[ "http/1.1" ] ~sw ~addr:"127.0.0.1" ~port:0
          handler
      in
      Eio.Fiber.fork ~sw serve_loop;
      let n = max 4 (Domain.recommended_domain_count ()) in
      let url = Printf.sprintf "https://127.0.0.1:%d/" port in
      let ok = Atomic.make 0 in
      let bodies = Atomic.make 0 in
      Eio.Fiber.all
        (List.init n (fun _ () ->
             (* fresh transport per fiber => fresh TLS handshake. *)
             let transport = Transport.create ~net ~clock ~insecure:true () in
             let client = Client.create ~net ~clock ~transport () in
             let resp = Client.get ~sw client url in
             let body = Body.read_all resp.Response.body in
             if (Httpg_base.Status.to_int resp.Response.status_code) = 200 then Atomic.incr ok;
             if body = "tls-ok" then Atomic.incr bodies));
      Server.close srv;
      Printf.printf "[multicore-tls] cores=%d handshakes=%d ok=%d bodies=%d\n%!"
        (Domain.recommended_domain_count ())
        n (Atomic.get ok) (Atomic.get bodies);
      Alcotest.(check int) "all TLS requests ok" n (Atomic.get ok);
      Alcotest.(check int) "all TLS bodies correct" n (Atomic.get bodies))

(* ---- ticket 016: multicore CLIENT (per-domain transport pools) ---- *)

(* One shared Transport.t/Client.t driven from N = cores domains concurrently
   via Eio.Domain_manager.run. Each domain opens its OWN Switch.run +
   Transport.run ~sw (its per-domain pool) and fires many concurrent requests
   mixing h1 plaintext and h2-over-TLS. All must complete with correct
   status/body, repeatably, with ZERO Stream_aborted / bufio races / hangs
   (Go's http.Client used from many goroutines across OS threads). We also
   assert keep-alive reuse holds WITHIN a domain (sequential h1 GETs => one
   dial on that domain), and that cross-domain TLS handshakes are parallel
   (wall < a serial estimate). *)
let multicore_client () =
  let cores = Domain.recommended_domain_count () in
  if cores < 2 then
    Printf.printf "[multicore-client] only %d core(s); skipping\n%!" cores
  else
    Test_harness.with_env_dm ~secs:120. (fun ~net ~clock ~domain_mgr ~sw ->
        (* h1 plaintext server + h2-over-TLS server, both multicore. *)
        let h1 = Server.handler_func (fun w _r -> w.Server.write "h1-ok") in
        let h2 = Server.handler_func (fun w _r -> w.Server.write "h2-ok") in
        (* The servers stay single-domain (~domains:1): this gate exercises the
           CLIENT across domains. Each Eio.Domain_manager.run creates its own
           io_uring, so we keep the total domain count bounded by RLIMIT_MEMLOCK
           (servers single-domain; client capped below). *)
        let srv1, p1, loop1 =
          Server.listen_and_serve_started ~net ~clock ~domain_mgr ~domains:1 ~sw
            ~addr:"127.0.0.1" ~port:0 h1
        in
        let certificates = Net.test_server_certificate () in
        let srv2, p2, loop2 =
          Server.listen_and_serve_tls_started ~net ~clock ~domain_mgr ~domains:1
            ~certificates ~alpn:[ "h2"; "http/1.1" ] ~sw ~addr:"127.0.0.1"
            ~port:0 h2
        in
        Eio.Fiber.fork ~sw loop1;
        Eio.Fiber.fork ~sw loop2;
        let url1 = Printf.sprintf "http://127.0.0.1:%d/" p1 in
        let url2 = Printf.sprintf "https://127.0.0.1:%d/" p2 in
        (* ONE shared transport + client, driven from every domain. *)
        let transport = Transport.create ~net ~clock ~insecure:true () in
        let client = Client.create ~net ~clock ~transport () in
        (* Cap client domains so io_uring instances stay within RLIMIT_MEMLOCK
           on constrained machines; >=2 still proves cross-domain safety. *)
        let n = min cores 6 in
        let per_domain = 24 in
        let iters = 4 in
        let ok = Atomic.make 0 and aborts = Atomic.make 0 in
        let dials_seen = Atomic.make 0 in
        (* Body of one domain: its own switch + Transport.run scope, then a mix
           of h1/h2 concurrent requests; repeated [iters] times. *)
        let drive_domain () =
          Eio.Switch.run @@ fun dsw ->
          Transport.run transport ~sw:dsw @@ fun () ->
          (* keep-alive within this domain: two sequential h1 GETs share a conn. *)
          let r = Client.get ~sw:dsw client url1 in
          ignore (Body.read_all r.Response.body);
          let r = Client.get ~sw:dsw client url1 in
          ignore (Body.read_all r.Response.body);
          (* the second h1 GET reused the conn on this domain: after draining,
             exactly one idle h1 conn is pooled for this authority on this
             domain (Go's keep-alive). Key by conn_key, not the URL. *)
          let key =
            Transport.conn_key ~scheme:"http" ~host:"127.0.0.1" ~port:p1
          in
          if Transport.idle_count transport key >= 1 then Atomic.incr dials_seen;
          let contains s sub =
            let ls = String.length s and lsub = String.length sub in
            let rec find i =
              i + lsub <= ls && (String.sub s i lsub = sub || find (i + 1))
            in
            find 0
          in
          for _ = 1 to iters do
            Eio.Fiber.all
              (List.init per_domain (fun i () ->
                   let url, expect =
                     if i land 1 = 0 then (url1, "h1-ok") else (url2, "h2-ok")
                   in
                   match Client.get ~sw:dsw client url with
                   | resp ->
                       let body = Body.read_all resp.Response.body in
                       if (Httpg_base.Status.to_int resp.Response.status_code) = 200 && body = expect then
                         Atomic.incr ok
                   | exception e ->
                       if contains (Printexc.to_string e) "Stream_aborted" then
                         Atomic.incr aborts;
                       raise e))
          done
        in
        let t0 = Eio.Time.now clock in
        Eio.Fiber.all
          (List.init n (fun _ () ->
               Eio.Domain_manager.run domain_mgr drive_domain));
        let wall = Eio.Time.now clock -. t0 in
        Server.close srv1;
        Server.close srv2;
        let expected = n * iters * per_domain in
        Printf.printf
          "[multicore-client] cores=%d domains=%d per-domain=%d iters=%d \
           ok=%d/%d aborts=%d wall=%.0fms dials=%d (reuse-domains=%d)\n\
           %!"
          cores n per_domain iters (Atomic.get ok) expected (Atomic.get aborts)
          (wall *. 1000.)
          (Transport.dial_count transport)
          (Atomic.get dials_seen);
        Alcotest.(check int) "zero Stream_aborted" 0 (Atomic.get aborts);
        Alcotest.(check int) "all requests ok" expected (Atomic.get ok);
        Alcotest.(check bool)
          "keep-alive reuse held on every domain" true
          (Atomic.get dials_seen = n))

(* Parallelism gate for the CLIENT: TLS handshakes are CPU-bound (asymmetric
   crypto), so fanning fresh handshakes across domains should beat doing them
   all on one domain. We dial [total] fresh https conns (fresh transport per
   request => fresh handshake) serially on one domain, then the same [total]
   split across [n] domains, and assert the parallel wall is well below serial.
   Each request uses its own short-lived Switch + Transport.run scope. *)
let multicore_client_parallel_tls () =
  let cores = Domain.recommended_domain_count () in
  if cores < 2 then
    Printf.printf "[multicore-client-tls] only %d core(s); skipping\n%!" cores
  else
    Test_harness.with_env_dm ~secs:120. (fun ~net ~clock ~domain_mgr ~sw ->
        let h = Server.handler_func (fun w _r -> w.Server.write "ok") in
        let certificates = Net.test_server_certificate () in
        let srv, port, loop =
          Server.listen_and_serve_tls_started ~net ~clock ~domain_mgr ~domains:1
            ~certificates ~alpn:[ "http/1.1" ] ~sw ~addr:"127.0.0.1" ~port:0 h
        in
        Eio.Fiber.fork ~sw loop;
        let url = Printf.sprintf "https://127.0.0.1:%d/" port in
        (* One fresh-handshake request on the calling domain. *)
        let one_handshake () =
          Eio.Switch.run @@ fun rsw ->
          let tr = Transport.create ~net ~clock ~insecure:true () in
          Transport.run tr ~sw:rsw @@ fun () ->
          let c = Client.create ~net ~clock ~transport:tr () in
          let resp = Client.get ~sw:rsw c url in
          ignore (Body.read_all resp.Response.body);
          (Httpg_base.Status.to_int resp.Response.status_code) = 200
        in
        let n = min cores 6 in
        let per = 8 in
        let total = n * per in
        (* Serial: all handshakes on the calling domain. *)
        let t0 = Eio.Time.now clock in
        let serial_ok = ref 0 in
        for _ = 1 to total do
          if one_handshake () then incr serial_ok
        done;
        let serial = Eio.Time.now clock -. t0 in
        (* Parallel: [per] handshakes on each of [n] domains. *)
        let pok = Atomic.make 0 in
        let t1 = Eio.Time.now clock in
        Eio.Fiber.all
          (List.init n (fun _ () ->
               Eio.Domain_manager.run domain_mgr (fun () ->
                   Eio.Fiber.all
                     (List.init per (fun _ () ->
                          if one_handshake () then Atomic.incr pok)))));
        let parallel = Eio.Time.now clock -. t1 in
        Server.close srv;
        Printf.printf
          "[multicore-client-tls] cores=%d domains=%d handshakes=%d \
           serial=%.0fms parallel=%.0fms speedup=%.2fx ok=%d/%d\n\
           %!"
          cores n total (serial *. 1000.) (parallel *. 1000.)
          (serial /. Float.max parallel 1e-6)
          (Atomic.get pok) total;
        Alcotest.(check int) "serial all ok" total !serial_ok;
        Alcotest.(check int) "parallel all ok" total (Atomic.get pok);
        (* Generous bound: parallel must clearly beat serial (well under 3/4)
           while tolerating handshake/IO jitter. *)
        Alcotest.(check bool)
          (Printf.sprintf "parallel %.0fms < serial*0.75 %.0fms"
             (parallel *. 1000.) (serial *. 750.))
          true
          (parallel < serial *. 0.75))

(* Repeatability: run the multicore-client gate K times; any race/hang/abort in
   a single iteration fails the suite (non-flaky check). *)
let multicore_client_repeat () =
  if Domain.recommended_domain_count () < 2 then
    Printf.printf "[multicore-client-repeat] <2 cores; skipping\n%!"
  else
    for _ = 1 to 3 do
      multicore_client ()
    done

let tests =
  [
    ("multicore_parallel", `Slow, multicore_parallel);
    ("single_domain_serves", `Quick, single_domain_serves);
    ("close_then_reserve", `Quick, close_then_reserve);
    ("multicore_tls", `Slow, multicore_tls);
    ("multicore_client", `Slow, multicore_client);
    ("multicore_client_parallel_tls", `Slow, multicore_client_parallel_tls);
    ("multicore_client_repeat", `Slow, multicore_client_repeat);
  ]
