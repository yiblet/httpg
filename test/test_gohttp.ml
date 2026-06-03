let () =
  Alcotest.run "gohttp"
    [
      ("Method", Test_method.tests);
      ("Status", Test_status.tests);
      ("Header", Test_header.tests);
      ("Sniff", Test_sniff.tests);
      ("Cookie", Test_cookie.tests);
      ("Transfer", Test_transfer.tests);
    ]
