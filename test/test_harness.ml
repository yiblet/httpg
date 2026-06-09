(* Shared Eio test harness. Suites that need IO call {!with_env} to obtain the
   net/clock capabilities and an enclosing switch, bounded by a timeout so a hang
   fails instead of blocking. Pure suites need none of this. *)

(* Run [fn ~net ~clock ~sw] under [Eio_main.run] + an enclosing switch, bounded
   by [secs] seconds (default 10.) so a hang surfaces as Eio.Time.Timeout. *)
let with_env ?(secs = 10.) fn =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  Eio.Time.with_timeout_exn clock secs @@ fun () ->
  Eio.Switch.run @@ fun sw -> fn ~net ~clock ~sw

(* Like {!with_env} but also exposes the domain manager (Eio.Stdenv.domain_mgr),
   for the multicore server tests. *)
let with_env_dm ?(secs = 10.) fn =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let domain_mgr = Eio.Stdenv.domain_mgr env in
  Eio.Time.with_timeout_exn clock secs @@ fun () ->
  Eio.Switch.run @@ fun sw -> fn ~net ~clock ~domain_mgr ~sw

(* The filesystem capability (Eio.Stdenv.fs), for [Fs] tests. *)
let with_fs ?(secs = 10.) fn =
  Eio_main.run @@ fun env ->
  let net = Eio.Stdenv.net env in
  let clock = Eio.Stdenv.clock env in
  let fs = Eio.Stdenv.fs env in
  Eio.Time.with_timeout_exn clock secs @@ fun () ->
  Eio.Switch.run @@ fun sw -> fn ~net ~clock ~sw ~fs

let add_timing_to_test ((n, s, f) : _ Alcotest.test_case) : _ Alcotest.test_case
    =
  ( n,
    s,
    fun () ->
      Printf.printf "\nRunning test %s\n" n;
      let start = Ptime_clock.now () in
      let _ = f () in
      let stop = Ptime_clock.now () in
      let diff = Ptime.diff stop start in
      if
        Ptime.Span.of_float_s 0.1
        |> Option.map (( > ) diff)
        |> Option.value ~default:false
      then
        Printf.eprintf "Test %s took %f seconds (SLOW)\n" n
          (Ptime.Span.to_float_s diff)
      else
        Printf.eprintf "Test %s took %f seconds\n" n
          (Ptime.Span.to_float_s diff) )

let time_tests = Sys.getenv_opt "HTTPG_TIME" <> None

(* Tests tagged [`Slow] (high iteration counts / real-clock timeout waits) are
   skipped by default so [dune test] stays fast; set HTTPG_SLOW=1 to run them.
   Wired into Alcotest's [quick_only] in test_httpg.ml — alcotest's own default
   runs slow tests, and its CLI [-q] can only force quick-only on, so this env
   gate is what lets the default stay fast while still allowing opt-in. *)
let run_slow = Sys.getenv_opt "HTTPG_SLOW" <> None

(* An in-memory Buf_read over a string (the strings.NewReader analogue). *)
let buf_read_of_string = Eio.Buf_read.of_string

(* Collect what [f] writes to a Buf_write into a string. *)
let with_output_string (f : Eio.Buf_write.t -> unit) : string =
  let w = Eio.Buf_write.create 256 in
  f w;
  Eio.Buf_write.serialize_to_string w
