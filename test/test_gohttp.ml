let () =
  Alcotest.run "gohttp"
    [
      ("Method", Test_method.tests);
      ("Status", Test_status.tests);
      ("Header", Test_header.tests);
    ]
