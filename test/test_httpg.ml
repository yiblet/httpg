(* Alcotest runner aggregating the full ported suite: HTTP/1.x, the h2
   framing-level suites, and the h2 server/transport/end-to-end round trips. *)
let () =
  (* Multicore tests open an io_uring per domain and are sensitive to
     RLIMIT_MEMLOCK; skipped by default, opt in with HTTPG_MULTICORE=1. *)
  let multicore =
    if Sys.getenv_opt "HTTPG_MULTICORE" <> None then
      [ ("Multicore", Test_multicore.tests) ]
    else []
  in
  (* [`Slow]-tagged tests are skipped unless HTTPG_SLOW=1 (see Test_harness). *)
  Alcotest.run
    ~quick_only:(not Test_harness.run_slow)
    "httpg"
    ([
       ("Header", Test_header.tests);
       ("Cookie", Test_cookie.tests);
       ("Http_time", Test_http_time.tests);
       ("Method", Test_method.tests);
       ("Protocol", Test_protocol.tests);
       ("Status", Test_status.tests);
       ("Values", Test_values.tests);
       ("Ascii", Test_ascii.tests);
       ("Mapping", Test_mapping.tests);
       ("Pattern", Test_pattern.tests);
       ("Routing_tree", Test_routing_tree.tests);
       ("Sniff", Test_sniff.tests);
       ("Transfer", Test_transfer.tests);
       ("Io", Test_io.tests);
       ("ReadRequest", Test_readrequest.tests);
       ("Request", Test_request.tests);
       ("RequestWrite", Test_requestwrite.tests);
       ("Response", Test_response.tests);
       ("ResponseWrite", Test_responsewrite.tests);
       ("Clientserver", Test_clientserver.tests);
       ("Serve", Test_serve.tests);
       ("Stream_client", Test_stream_client.tests);
       ("Stream_read", Test_stream_read.tests);
       ("Stream_write", Test_stream_write.tests);
       ("Net", Test_net.tests);
       ("Fs", Test_fs.tests);
       ("Fs_conditional", Test_fs_conditional.tests);
       ("Fs_range", Test_fs_range.tests);
       ("Httptest_server", Test_httptest_server.tests);
       ("Request_form", Test_request_form.tests);
       ("Abuse", Test_abuse.tests);
       ("Error_policy", Test_error_policy.tests);
       ("H2", Test_h2.tests);
       ("H2Frame", Test_h2_frame.tests);
       ("Hpack", Test_hpack.tests);
       ("HpackTables", Test_hpack_tables.tests);
       ("H2Databuffer", Test_h2_databuffer.tests);
       ("H2Flow", Test_h2_flow.tests);
       ("H2Write", Test_h2_write.tests);
       ("H2Writesched", Test_h2_writesched.tests);
       ("H2Pipe", Test_h2_pipe.tests);
       ("H2Server", Test_h2_server.tests);
       ("H2Transport", Test_h2_transport.tests);
       ("H2Tls", Test_h2_tls.tests);
       ("H2Clientserver", Test_h2_clientserver.tests);
       ("Stream_h2", Test_stream_h2.tests);
       ("Abuse_h2", Test_abuse_h2.tests);
     ]
    @ multicore)
