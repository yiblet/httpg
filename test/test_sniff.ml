open Gohttp

let check desc data expected () =
  Alcotest.(check string) desc expected (Sniff.detect_content_type data)

(* Ported from go/src/net/http/sniff_test.go sniffTests (TestDetectContentType).
   The net-based TestServerContentTypeSniff / TestServerIssue5953 /
   TestContentTypeWithVariousSources / TestSniffWriteSize are server-behavior
   tests deferred to a later ticket. *)
let tests =
  [
    (* Some nonsense. *)
    ("Empty", `Quick, check "Empty" "" "text/plain; charset=utf-8");
    ("Binary", `Quick, check "Binary" "\x01\x02\x03" "application/octet-stream");
    ( "HTML document #1",
      `Quick,
      check "HTML document #1" "<HtMl><bOdY>blah blah blah</body></html>"
        "text/html; charset=utf-8" );
    ( "HTML document #2",
      `Quick,
      check "HTML document #2" "<HTML></HTML>" "text/html; charset=utf-8" );
    ( "HTML document #3 (leading whitespace)",
      `Quick,
      check "HTML document #3" "   <!DOCTYPE HTML>..."
        "text/html; charset=utf-8" );
    ( "HTML document #4 (leading CRLF)",
      `Quick,
      check "HTML document #4" "\r\n<html>..." "text/html; charset=utf-8" );
    ( "Plain text",
      `Quick,
      check "Plain text" "This is not HTML. It has \xe2\x98\x83 though."
        "text/plain; charset=utf-8" );
    ("XML", `Quick, check "XML" "\n<?xml!" "text/xml; charset=utf-8");
    (* Image types. *)
    ( "Windows icon",
      `Quick,
      check "Windows icon" "\x00\x00\x01\x00" "image/x-icon" );
    ( "Windows cursor",
      `Quick,
      check "Windows cursor" "\x00\x00\x02\x00" "image/x-icon" );
    ("BMP image", `Quick, check "BMP image" "BM..." "image/bmp");
    ("GIF 87a", `Quick, check "GIF 87a" "GIF87a" "image/gif");
    ("GIF 89a", `Quick, check "GIF 89a" "GIF89a..." "image/gif");
    ( "WEBP image",
      `Quick,
      check "WEBP image" "RIFF\x00\x00\x00\x00WEBPVP" "image/webp" );
    ( "PNG image",
      `Quick,
      check "PNG image" "\x89PNG\x0D\x0A\x1A\x0A" "image/png" );
    ("JPEG image", `Quick, check "JPEG image" "\xFF\xD8\xFF" "image/jpeg");
    (* Audio types. *)
    ( "MIDI audio",
      `Quick,
      check "MIDI audio" "MThd\x00\x00\x00\x06\x00\x01" "audio/midi" );
    ( "MP3 audio/MPEG audio",
      `Quick,
      check "MP3 audio" "ID3\x03\x00\x00\x00\x00\x0f" "audio/mpeg" );
    ( "WAV audio #1",
      `Quick,
      check "WAV audio #1" "RIFFb\xb8\x00\x00WAVEfmt \x12\x00\x00\x00\x06"
        "audio/wave" );
    ( "WAV audio #2",
      `Quick,
      check "WAV audio #2" "RIFF,\x00\x00\x00WAVEfmt \x12\x00\x00\x00\x06"
        "audio/wave" );
    ( "AIFF audio #1",
      `Quick,
      check "AIFF audio #1"
        "FORM\x00\x00\x00\x00AIFFCOMM\x00\x00\x00\x12\x00\x01\x00\x00\x57\x55\x00\x10\x40\x0d\xf3\x34"
        "audio/aiff" );
    ( "OGG audio",
      `Quick,
      check "OGG audio"
        "OggS\x00\x02\x00\x00\x00\x00\x00\x00\x00\x00\x7e\x46\x00\x00\x00\x00\x00\x00\x1f\xf6\xb4\xfc\x01\x1e\x01\x76\x6f\x72"
        "application/ogg" );
    ( "Must not match OGG (owow)",
      `Quick,
      check "Must not match OGG" "owow\x00" "application/octet-stream" );
    ( "Must not match OGG (oooS)",
      `Quick,
      check "Must not match OGG" "oooS\x00" "application/octet-stream" );
    ( "Must not match OGG (oggS)",
      `Quick,
      check "Must not match OGG" "oggS\x00" "application/octet-stream" );
    (* Video types. *)
    ( "MP4 video",
      `Quick,
      check "MP4 video"
        "\x00\x00\x00\x18ftypmp42\x00\x00\x00\x00mp42isom<\x06t\xbfmdat"
        "video/mp4" );
    ( "AVI video #1",
      `Quick,
      check "AVI video #1" "RIFF,O\n\x00AVI LIST\xc3\x80" "video/avi" );
    ( "AVI video #2",
      `Quick,
      check "AVI video #2" "RIFF,\n\x00\x00AVI LIST\xc3\x80" "video/avi" );
    (* Font types. *)
    ( "TTF sample I",
      `Quick,
      check "TTF sample I"
        "\x00\x01\x00\x00\x00\x17\x01\x00\x00\x04\x01\x60\x4f" "font/ttf" );
    ( "TTF sample II",
      `Quick,
      check "TTF sample II"
        "\x00\x01\x00\x00\x00\x0e\x00\x80\x00\x03\x00\x60\x46" "font/ttf" );
    ( "OTTO sample I",
      `Quick,
      check "OTTO sample I"
        "\x4f\x54\x54\x4f\x00\x0e\x00\x80\x00\x03\x00\x60\x42\x41\x53\x45"
        "font/otf" );
    ( "woff sample I",
      `Quick,
      check "woff sample I"
        "\x77\x4f\x46\x46\x00\x01\x00\x00\x00\x00\x30\x54\x00\x0d\x00\x00"
        "font/woff" );
    ( "woff2 sample",
      `Quick,
      check "woff2 sample" "\x77\x4f\x46\x32\x00\x01\x00\x00\x00" "font/woff2"
    );
    ( "wasm sample",
      `Quick,
      check "wasm sample" "\x00\x61\x73\x6d\x01\x00" "application/wasm" );
    (* Archive types. *)
    ( "RAR v1.5-v4.0",
      `Quick,
      check "RAR v1.5-v4.0" "Rar!\x1A\x07\x00" "application/x-rar-compressed" );
    ( "RAR v5+",
      `Quick,
      check "RAR v5+" "Rar!\x1A\x07\x01\x00" "application/x-rar-compressed" );
    ( "Incorrect RAR v1.5-v4.0",
      `Quick,
      check "Incorrect RAR v1.5-v4.0" "Rar \x1A\x07\x00"
        "application/octet-stream" );
    ( "Incorrect RAR v5+",
      `Quick,
      check "Incorrect RAR v5+" "Rar \x1A\x07\x01\x00"
        "application/octet-stream" );
  ]
