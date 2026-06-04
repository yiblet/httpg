(* Port of go/src/net/http/internal/common.go.

   Go centralizes these sentinel errors in the internal package so both net/http
   and internal/http2 can share them. In this port the corresponding features
   are either unported (handler-abort, alternate-protocol registration) or use a
   different idiom (request cancellation flows through [Context.Canceled];
   body suppression uses the [body_allowed_for_status] predicate rather than a
   raised error). The exceptions are defined here for structural fidelity and to
   be wired up when those features land. *)

(* Go ErrAbortHandler ("net/http: abort Handler"): a sentinel a handler may
   raise to abort silently. Wired once server handler-panic recovery is ported. *)
exception Abort_handler

(* Go ErrBodyNotAllowed ("http: request method or response status code does not
   allow body"): returned by Go's response write path. Our port instead
   suppresses the body via [Server.body_allowed_for_status] /
   [Transfer.body_allowed_for_status]. *)
exception Body_not_allowed

(* Go ErrRequestCanceled ("net/http: request canceled"). Our port models request
   cancellation via [Context.Canceled]; this is the net/http-level name. *)
exception Request_canceled

(* Go ErrSkipAltProtocol ("net/http: skip alternate protocol"). Alternate
   protocol registration (RegisterProtocol) is not ported. *)
exception Skip_alt_protocol
