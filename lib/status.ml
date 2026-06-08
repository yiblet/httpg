(* Public re-export: [Httpg.Status] is [Httpg_base.Status] (the typed HTTP
   status codes live in the foundation library; this exposes them under the
   public [Httpg] namespace so consumers can write [Httpg.Status]). *)
include Httpg_base.Status
