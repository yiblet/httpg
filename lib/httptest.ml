(* Port of go/src/net/http/httptest/recorder.go (ResponseRecorder). *)

module Response_recorder = struct
  type t = {
    mutable code : int;
    header : Header.t;
    body : Buffer.t;
    mutable flushed : bool;
    mutable wrote_header : bool;
    mutable snap_header : Header.t option;
    mutable default_remote_addr : string;
  }

  let default_remote_addr_const = "1.2.3.4"

  (* NewRecorder: Code defaults to 200. *)
  let create () =
    {
      code = 200;
      header = Header.create ();
      body = Buffer.create 256;
      flushed = false;
      wrote_header = false;
      snap_header = None;
      default_remote_addr = "";
    }

  (* checkWriteHeaderCode: require a 3-digit status code. *)
  let check_write_header_code code =
    if code < 100 || code > 999 then
      invalid_arg (Printf.sprintf "invalid WriteHeader code %d" code)

  (* WriteHeader(code): first call wins; record code + snapshot header. *)
  let write_header_code t code =
    if not t.wrote_header then begin
      check_write_header_code code;
      t.code <- code;
      t.wrote_header <- true;
      t.snap_header <- Some (Header.clone t.header)
    end

  (* writeHeader(b): detect Content-Type if needed, then WriteHeader(200).
     [b] is the beginning of the response body (first write). *)
  let write_header_implicit t b =
    if not t.wrote_header then begin
      let b = if String.length b > 512 then String.sub b 0 512 else b in
      let has_type = Header.has t.header "Content-Type" in
      let has_te = Header.get t.header "Transfer-Encoding" <> "" in
      if (not has_type) && not has_te then
        Header.set t.header "Content-Type" (Sniff.detect_content_type b);
      write_header_code t 200
    end

  let write t s =
    write_header_implicit t s;
    Buffer.add_string t.body s;
    Lwt.return_unit

  let flush t =
    if not t.wrote_header then write_header_code t 200;
    t.flushed <- true;
    Lwt.return_unit

  let to_response_writer (t : t) : Server.response_writer =
    {
      header = (fun () -> t.header);
      write_header = (fun code -> write_header_code t code);
      write = (fun s -> write t s);
      flush = (fun () -> flush t);
    }

  (* parseContentLength: trim, "" -> -1, parse as unsigned 63-bit int, else
     -1. Mirrors recorder.go:parseContentLength (rejects "+3", "-3" and
     values > max int64). *)
  let parse_content_length cl =
    let cl = String.trim cl in
    if cl = "" then -1L
    else if not (String.for_all (fun c -> c >= '0' && c <= '9') cl) then -1L
    else
      match Int64.of_string_opt cl with
      | Some n when n >= 0L && n <= Int64.max_int -> n
      | _ -> -1L

  let result (t : t) : Body.t Response.t =
    let snap =
      match t.snap_header with
      | Some h -> h
      | None ->
          let h = Header.clone t.header in
          t.snap_header <- Some h;
          h
    in
    let status_code = if t.code = 0 then 200 else t.code in
    let status =
      Printf.sprintf "%03d %s" status_code (Status.status_text status_code)
    in
    let content_length =
      parse_content_length (Header.get snap "Content-Length")
    in
    {
      Response.status;
      status_code;
      proto = "HTTP/1.1";
      proto_major = 1;
      proto_minor = 1;
      header = snap;
      body = Body.String (Buffer.contents t.body);
      content_length;
      transfer_encoding = [];
      close = false;
      uncompressed = false;
      trailer = None;
      request = None;
    }

  let code t = t.code
  let body_string t = Buffer.contents t.body
  let header t = t.header
end
