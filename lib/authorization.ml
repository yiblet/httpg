(* HTTP Authorization header values (RFC 7235): scheme + credentials. See
   authorization.mli. Basic/Bearer are first-class; other schemes round-trip
   verbatim via Other. *)

type t =
  | Basic of { username : string; password : string }
  | Bearer of string
  | Other of { scheme : string; params : string }

type error = Malformed of string | Invalid_basic

let error_to_string = function
  | Malformed s -> Printf.sprintf "malformed Authorization header: %S" s
  | Invalid_basic -> "invalid Basic credentials"

let eq_fold = Httpg_internal.Ascii.equal_fold

let to_string = function
  | Basic { username; password } ->
      "Basic " ^ Base64.encode_string (username ^ ":" ^ password)
  | Bearer token -> "Bearer " ^ token
  | Other { scheme; params } -> scheme ^ " " ^ params

(* Decode a Basic payload (base64 of "user:pass") into its parts. *)
let parse_basic params =
  match Base64.decode params with
  | (exception _) | Error _ -> Error Invalid_basic
  | Ok decoded -> (
      match String.index_opt decoded ':' with
      | None -> Error Invalid_basic
      | Some i ->
          Ok
            (Basic
               {
                 username = String.sub decoded 0 i;
                 password =
                   String.sub decoded (i + 1) (String.length decoded - i - 1);
               }))

let of_string s =
  let s = String.trim s in
  match String.index_opt s ' ' with
  | None -> Error (Malformed s)
  | Some i ->
      let scheme = String.sub s 0 i in
      let params =
        String.trim (String.sub s (i + 1) (String.length s - i - 1))
      in
      if eq_fold scheme "Basic" then parse_basic params
      else if eq_fold scheme "Bearer" then Ok (Bearer params)
      else Ok (Other { scheme; params })
