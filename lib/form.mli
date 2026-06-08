(* Form values: the port of go/src/net/url [Values] (= map[string][]string) with
   ParseQuery/Encode, plus the application/x-www-form-urlencoded body parser
   {!of_body}. One module because a query string and a urlencoded body are the
   same wire format — both decode into the same {!t}; only the source differs.

   Like {!Header}, the multimap is a {b persistent} [Map] keyed by the raw
   (case-sensitive) key: the mutators {!add}/{!set}/{!del} return a new {!t}, so a
   value can be shared and forked freely. Deviation from Go's Request-mutating
   [ParseForm]: parsing is a pure function and there is no source-blind
   [Form]/[PostForm] merge — compose {!parse_query} on [Uri.verbatim_query
   req.url] (the query half) with {!of_body} (the body half) via {!merge}
   explicitly if wanted. multipart/form-data is in {!Multipart}. *)

type t
(** Go's [url.Values]: a persistent map from key to an ordered list of values
    (keys are case-sensitive, not canonicalized). *)

val create : unit -> t
(** A fresh, empty {!t}. *)

val get : t -> string -> string
(** [Values.Get]: the first value for the key, or "". *)

val set : t -> string -> string -> t
(** [Values.Set]: return [t] with any existing values for the key replaced. *)

val add : t -> string -> string -> t
(** [Values.Add]: return [t] with [value] appended to the key's list. *)

val del : t -> string -> t
(** [Values.Del]: return [t] without the key. *)

val has : t -> string -> bool
(** [Values.Has]: whether the key is present. *)

val find : t -> string -> string list
(** All values for the key (Go's [v[key]]); [] when absent. *)

val length : t -> int
(** Number of distinct keys ([len(v)]). *)

val merge : t -> t -> t
(** [merge a b] (functional [copyValues]): [a] with each of [b]'s values
    appended per key, [a]'s first. Combines the query and body halves into the
    Go-style merged [Form]. *)

val query_unescape : string -> string
(** Percent-decode a query component, accepting '+' as a space (browser/Go
    compatible). *)

val query_escape : string -> string
(** Percent-encode a query component. Deviation from Go: space is encoded as
    "%20" (not '+'); a literal '+' is encoded as "%2B", so the result
    round-trips through {!query_unescape}. *)

type error =
  | Invalid_semicolon_separator
  | Invalid_escape of string
  | Too_large
      (** A handleable form-parse failure.
          - {!Invalid_semicolon_separator}/{!Invalid_escape}: Go's [ParseQuery]
            error cases (the latter carries the offending fragment; declared for
            fidelity, though the [uri]-backed [query_unescape] does not
            currently surface bad-escape errors).
          - {!Too_large}: an urlencoded body over [max_form_size] ({!of_body}
            only). *)

val error_to_string : error -> string
(** Render an {!error} as Go's faithful message. *)

val parse_query : string -> t * (unit, error) result
(** [ParseQuery query]: the parsed map plus the first decode error, if any. *)

val encode : t -> string
(** [Values.Encode]: "k=v&..." sorted by key. *)

val of_body : Body.t -> (t, error) result
(** [of_body body] reads [body] fully and parses it as
    application/x-www-form-urlencoded (Go's [parsePostForm], minus the
    content-type gate — that is the caller's concern). [Error Too_large] if the
    body exceeds 10 MB; otherwise the first decode error from {!parse_query}. *)
