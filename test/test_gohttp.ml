let () =
  Alcotest.run "gohttp"
    [
      ("Method", Test_method.tests);
      ("Status", Test_status.tests);
      ("Header", Test_header.tests);
      ("Sniff", Test_sniff.tests);
      ("Cookie", Test_cookie.tests);
      ("Transfer", Test_transfer.tests);
      ("Request", Test_request.tests);
      ("ReadRequest", Test_readrequest.tests);
      ("RequestWrite", Test_requestwrite.tests);
      ("Response", Test_response.tests);
      ("ResponseWrite", Test_responsewrite.tests);
      ("Net", Test_net.tests);
      ("Mapping", Test_mapping.tests);
      ("Pattern", Test_pattern.tests);
      ("RoutingTree", Test_routing_tree.tests);
      ("Ascii", Test_ascii.tests);
    ]
