(* Port of golang.org/x/net/http2/hpack/static_table.go and the table
   machinery of tables.go (plus [HeaderField] and [dynamicTable] from
   hpack.go). Pure, no IO. *)

(** A name-value pair. Both name and value are opaque octet sequences.
    Mirrors Go's [HeaderField]. *)
type header_field = { name : string; value : string; sensitive : bool }

(** [is_pseudo hf] reports whether the field name starts with a colon.
    Mirrors Go's [HeaderField.IsPseudo]. *)
val is_pseudo : header_field -> bool

(** [size hf] is the RFC 7541 section 4.1 size of the entry:
    [len name + len value + 32]. Mirrors Go's [HeaderField.Size]. *)
val size : header_field -> int

(** A list of header fields backing the static and dynamic tables.
    Mirrors Go's [headerFieldTable]. *)
type header_field_table

(** [create_table ()] builds an empty dynamic-style table. Mirrors a
    zero-value [headerFieldTable] with [init] called. *)
val create_table : unit -> header_field_table

(** Number of entries currently in the table. Mirrors Go's [table.len]. *)
val table_len : header_field_table -> int

(** [add_entry t f] appends [f]. Mirrors Go's [addEntry]. *)
val add_entry : header_field_table -> header_field -> unit

(** [evict_oldest t n] evicts the [n] oldest entries. Mirrors [evictOldest].
    Raises [Invalid_argument] if [n] exceeds the table length. *)
val evict_oldest : header_field_table -> int -> unit

(** [search t f] finds [f]. Returns [(0, false)] for no match; [(i, true)]
    when name and value match; [(i, false)] when only the name matches. The
    returned index is a 1-based HPACK index. Mirrors Go's [search]. *)
val search : header_field_table -> header_field -> int * bool

(** The 61-entry static table as a fixed array (1-based HPACK indices map to
    [static_table.(i-1)]). Mirrors Go's [staticTable.ents]. *)
val static_table : header_field array

(** Number of static-table entries (61). Mirrors [staticTable.len()]. *)
val static_table_len : int

(** [static_table_entry i] returns the static entry at 1-based HPACK index
    [i] (1..61). Raises [Invalid_argument] otherwise. *)
val static_table_entry : int -> header_field

(** [static_search f] searches the global static table. Same contract as
    {!search}. Mirrors [staticTable.search]. *)
val static_search : header_field -> int * bool

(** The HPACK dynamic table with size accounting and eviction.
    Mirrors Go's [dynamicTable]. *)
type dynamic_table

(** [create_dynamic_table max_size] builds a dynamic table with the given
    initial (and allowed) max size in bytes. Mirrors the [dynTab] setup in
    [NewDecoder]. *)
val create_dynamic_table : int -> dynamic_table

(** Current size of the dynamic table in bytes. Mirrors [dynamicTable.size]. *)
val dynamic_size : dynamic_table -> int

(** Current max size of the dynamic table in bytes. Mirrors
    [dynamicTable.maxSize]. *)
val dynamic_max_size : dynamic_table -> int

(** Allowed upper bound for the max size. Mirrors [allowedMaxSize]. *)
val dynamic_allowed_max_size : dynamic_table -> int

(** [set_allowed_max_size dt v] sets the allowed upper bound. *)
val set_allowed_max_size : dynamic_table -> int -> unit

(** Number of entries in the dynamic table. *)
val dynamic_len : dynamic_table -> int

(** [set_max_size dt v] updates the max size and evicts as needed.
    Mirrors [setMaxSize]. *)
val set_max_size : dynamic_table -> int -> unit

(** [dynamic_add dt f] adds [f] then evicts to fit. Mirrors [add]. *)
val dynamic_add : dynamic_table -> header_field -> unit

(** [dynamic_table_of dt] exposes the underlying field table (for indexed
    lookup / search by the encoder). Mirrors [dynamicTable.table]. *)
val dynamic_table_of : dynamic_table -> header_field_table

(** [at dt i] returns the entry at the combined 1-based HPACK index [i]:
    static indices [1..61], dynamic entries after (newest lowest).
    Returns [None] for [i = 0] or out of range. Mirrors Go's [Decoder.at]. *)
val at : dynamic_table -> int -> header_field option
