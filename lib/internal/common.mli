(* Port of go/src/net/http/internal/common.go: the four net/http sentinel error
   values, as exceptions. See common.ml for why most are defined-ahead-of-use in
   this port. *)

(* Go ErrAbortHandler: a handler may raise this to abort silently. *)
exception Abort_handler

(* Go ErrBodyNotAllowed: the request method or status code does not allow a
   body. *)
exception Body_not_allowed

(* Go ErrRequestCanceled. (Request cancellation in this port flows through
   [Context.Canceled].) *)
exception Request_canceled

(* Go ErrSkipAltProtocol. (Alternate-protocol registration is not ported.) *)
exception Skip_alt_protocol
