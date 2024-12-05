let src = Logs.Src.create "miou.solo5"

module Log = (val Logs.src_log src : Logs.LOG)

type bigstring =
  (char, Bigarray.int8_unsigned_elt, Bigarray.c_layout) Bigarray.Array1.t

external bigstring_get_uint8 : bigstring -> int -> int = "%caml_ba_ref_1"

external bigstring_set_uint8 : bigstring -> int -> int -> unit
  = "%caml_ba_set_1"

external bigstring_get_int32_ne : bigstring -> int -> int32
  = "%caml_bigstring_get32"

external bigstring_set_int32_ne : bigstring -> int -> int32 -> unit
  = "%caml_bigstring_set32"

let bigstring_blit_to_bytes bstr ~src_off dst ~dst_off ~len =
  let len0 = len land 3 in
  let len1 = len lsr 2 in
  for i = 0 to len1 - 1 do
    let i = i * 4 in
    let v = bigstring_get_int32_ne bstr (src_off + i) in
    Bytes.set_int32_ne dst (dst_off + i) v
  done;
  for i = 0 to len0 - 1 do
    let i = (len1 * 4) + i in
    let v = bigstring_get_uint8 bstr (src_off + i) in
    Bytes.set_uint8 dst (dst_off + i) v
  done

let bigstring_blit_from_string src ~src_off dst ~dst_off ~len =
  let len0 = len land 3 in
  let len1 = len lsr 2 in
  for i = 0 to len1 - 1 do
    let i = i * 4 in
    let v = String.get_int32_ne src (src_off + i) in
    bigstring_set_int32_ne dst (dst_off + i) v
  done;
  for i = 0 to len0 - 1 do
    let i = (len1 * 4) + i in
    let v = String.get_uint8 src (src_off + i) in
    bigstring_set_uint8 dst (dst_off + i) v
  done

external miou_solo5_net_read :
     (int[@untagged])
  -> bigstring
  -> (int[@untagged])
  -> (int[@untagged])
  -> bytes
  -> int = "unimplemented" "miou_solo5_net_read"
[@@noalloc]

external miou_solo5_net_write :
     (int[@untagged])
  -> (int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_net_write"
[@@noalloc]

external miou_solo5_block_read :
     (int[@untagged])
  -> (int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_block_read"
[@@noalloc]

external miou_solo5_block_write :
     (int[@untagged])
  -> (int[@untagged])
  -> (int[@untagged])
  -> bigstring
  -> (int[@untagged]) = "unimplemented" "miou_solo5_block_write"
[@@noalloc]

external unsafe_get_int64_ne : bytes -> int -> int64 = "%caml_bytes_get64u"

let invalid_argf fmt = Format.kasprintf invalid_arg fmt

module Block_direct = struct
  type t = { handle: int; pagesize: int }

  let unsafe_read t ~off bstr =
    match miou_solo5_block_read t.handle off t.pagesize bstr with
    | 0 -> ()
    | 2 -> invalid_arg "Miou_solo5.Block.read"
    | _ -> assert false (* AGAIN | UNSPEC *)

  let atomic_read t ~off bstr =
    if off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Miou_solo5.Block.atomic_read: [off] must be aligned to the pagesize \
         (%d)"
        t.pagesize;
    if Bigarray.Array1.dim bstr < t.pagesize then
      invalid_argf
        "Miou_solo5.Block.atomic_read: length of [bstr] must be greater than \
         or equal to one page (%d)"
        t.pagesize;
    unsafe_read t ~off bstr

  let unsafe_write t ~off bstr =
    match miou_solo5_block_write t.handle off t.pagesize bstr with
    | 0 -> ()
    | 2 -> invalid_arg "Miou_solo5.Block.write"
    | _ -> assert false (* AGAIN | UNSPEC *)

  let atomic_write t ~off bstr =
    if off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Miou_solo5.Block.atomic_write: [off] must be aligned to the pagesize \
         (%d)"
        t.pagesize;
    if Bigarray.Array1.dim bstr < t.pagesize then
      invalid_argf
        "Miou_solo5.Block.atomic_write: length of [bstr] must be greater than \
         or equal to one page (%d)"
        t.pagesize;
    unsafe_write t ~off bstr
end

module Handles = struct
  type 'a t = { mutable contents: (int * 'a) list }

  let find tbl fd = List.assq fd tbl.contents

  let replace tbl fd v' =
    let contents =
      List.fold_left
        (fun acc (k, v) -> if k = fd then (k, v') :: acc else (k, v) :: acc)
        [] tbl.contents
    in
    tbl.contents <- contents

  let add tbl k v = tbl.contents <- (k, v) :: tbl.contents
  let clear tbl = tbl.contents <- []
  let create _ = { contents= [] }

  let append t k v =
    try
      let vs = find t k in
      replace t k (v :: vs)
    with Not_found -> add t k [ v ]

  let fold_left_map fn acc t =
    let acc, contents = List.fold_left_map fn acc t.contents in
    t.contents <- contents;
    acc

  let filter_map fn t =
    let contents = List.filter_map fn t.contents in
    t.contents <- contents
end

type elt = { time: int; syscall: Miou.syscall; mutable cancelled: bool }

module Heapq = struct
  include Miou.Pqueue.Make (struct
    type t = elt

    let dummy = { time= 0; syscall= Obj.magic (); cancelled= false }
    let compare { time= a; _ } { time= b; _ } = Int.compare a b
  end)

  let rec drop heapq = try delete_min_exn heapq; drop heapq with _ -> ()
end

type action = Rd of arguments | Wr of arguments

and arguments = {
    t: Block_direct.t
  ; bstr: bigstring
  ; off: int
  ; syscall: Miou.syscall
  ; mutable cancelled: bool
}

type domain = {
    handles: Miou.syscall list Handles.t
  ; sleepers: Heapq.t
  ; blocks: action Queue.t
}

let domain =
  let rec split_from_parent v =
    Handles.clear v.handles;
    Heapq.drop v.sleepers;
    Queue.clear v.blocks;
    make ()
  and make () =
    {
      handles= Handles.create 0x100
    ; sleepers= Heapq.create ()
    ; blocks= Queue.create ()
    }
  in
  let key = Stdlib.Domain.DLS.new_key ~split_from_parent make in
  fun () -> Stdlib.Domain.DLS.get key

let blocking_read fd =
  let syscall = Miou.syscall () in
  let domain = domain () in
  Log.debug (fun m -> m "append [%d] as a reader" fd);
  Handles.append domain.handles fd syscall;
  Miou.suspend syscall

module Net = struct
  type t = int

  let rec read t ~off ~len bstr =
    let read_size = Bytes.make 8 '\000' in
    let result = miou_solo5_net_read t bstr off len read_size in
    let read_size = Int64.to_int (unsafe_get_int64_ne read_size 0) in
    match result with
    | 0 -> read_size
    | 1 -> blocking_read t; read t ~off ~len bstr
    | 2 -> invalid_arg "Miou_solo5.Net.read"
    | _ -> assert false (* UNSPEC *)

  let read_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Miou_solo5.Net.read_bigstring: out of bounds";
    read t ~off ~len bstr

  let read_bytes =
    let bstr = Bigarray.(Array1.create char c_layout 0x7ff) in
    fun t ?(off = 0) ?len buf ->
      let rec go dst_off dst_len =
        if dst_len > 0 then begin
          let len = Int.min (Bigarray.Array1.dim bstr) dst_len in
          let len = read_bigstring t ~off:0 ~len bstr in
          bigstring_blit_to_bytes bstr ~src_off:0 buf ~dst_off ~len;
          if len > 0 then go (dst_off + len) (dst_len - len) else dst_off - off
        end
        else dst_off - off
      in
      let len =
        match len with Some len -> len | None -> Bytes.length buf - off
      in
      if len < 0 || off < 0 || off > Bytes.length buf - len then
        invalid_arg "Miou_solo5.Net.read_bytes: out of bounds";
      go off len

  let write t ~off ~len bstr =
    match miou_solo5_net_write t off len bstr with
    | 0 -> ()
    | 2 -> invalid_arg "Miou_solo5.Net.write"
    | _ -> assert false (* AGAIN | UNSPEC *)

  let write_bigstring t ?(off = 0) ?len bstr =
    let len =
      match len with Some len -> len | None -> Bigarray.Array1.dim bstr - off
    in
    if len < 0 || off < 0 || off > Bigarray.Array1.dim bstr - len then
      invalid_arg "Miou_solo5.Net.write_bigstring: out of bounds";
    write t ~off ~len bstr

  let write_string =
    let bstr = Bigarray.(Array1.create char c_layout 0x7ff) in
    fun t ?(off = 0) ?len str ->
      let rec go src_off src_len =
        if src_len > 0 then begin
          let len = Int.min (Bigarray.Array1.dim bstr) src_len in
          bigstring_blit_from_string str ~src_off bstr ~dst_off:0 ~len;
          write_bigstring t ~off:0 ~len bstr;
          Miou.yield ();
          go (src_off + len) (src_len - len)
        end
      in
      let len =
        match len with Some len -> len | None -> String.length str - off
      in
      if len < 0 || off < 0 || off > String.length str - len then
        invalid_arg "Miou_solo5.Net.write_string: out of bounds";
      go off len
end

module Block = struct
  include Block_direct

  let read t ~off bstr =
    if off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Miou_solo5.Block.read: [off] must be aligned to the pagesize (%d)"
        t.pagesize;
    if Bigarray.Array1.dim bstr < t.pagesize then
      invalid_argf
        "Miou_solo5.Block.read: length of [bstr] must be greater than or equal \
         to one page (%d)"
        t.pagesize;
    let syscall = Miou.syscall () in
    let args = { t; bstr; off; syscall; cancelled= false } in
    let domain = domain () in
    Queue.push (Rd args) domain.blocks;
    Miou.suspend syscall

  let write t ~off bstr =
    if off land (t.pagesize - 1) != 0 then
      invalid_argf
        "Miou_solo5.Block.write: [off] must be aligned to the pagesize (%d)"
        t.pagesize;
    if Bigarray.Array1.dim bstr < t.pagesize then
      invalid_argf
        "Miou_solo5.Block.write: length of [bstr] must be greater than or \
         equal to one page (%d)"
        t.pagesize;
    let syscall = Miou.syscall () in
    let args = { t; bstr; off; syscall; cancelled= false } in
    let domain = domain () in
    Queue.push (Wr args) domain.blocks;
    Miou.suspend syscall
end

external clock_monotonic : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_monotonic"
[@@noalloc]

external clock_wall : unit -> (int[@untagged])
  = "unimplemented" "miou_solo5_clock_wall"
[@@noalloc]

let sleep until =
  let syscall = Miou.syscall () in
  let domain = domain () in
  let elt = { time= clock_monotonic () + until; syscall; cancelled= false } in
  Heapq.insert elt domain.sleepers;
  Miou.suspend syscall

(* poll part of Miou_solo5 *)

let rec sleeper domain =
  match Heapq.find_min_exn domain.sleepers with
  | exception Heapq.Empty -> None
  | { cancelled= true; _ } ->
      Heapq.delete_min_exn domain.sleepers;
      sleeper domain
  | { time; _ } -> Some time

let in_the_past t = t == 0 || t <= clock_monotonic ()

let rec collect_sleepers domain signals =
  match Heapq.find_min_exn domain.sleepers with
  | exception Heapq.Empty -> signals
  | { cancelled= true; _ } ->
      Heapq.delete_min_exn domain.sleepers;
      collect_sleepers domain signals
  | { time; syscall; _ } when in_the_past time ->
      Heapq.delete_min_exn domain.sleepers;
      collect_sleepers domain (Miou.signal syscall :: signals)
  | _ -> signals

let collect_handles ~handles domain signals =
  let fn acc (handle, syscalls) =
    if (1 lsl handle) land handles != 0 then
      let signals = List.rev_map Miou.signal syscalls in
      (List.rev_append signals acc, (handle, []))
    else (acc, (handle, syscalls))
  in
  Handles.fold_left_map fn signals domain.handles

let rec consume_block domain signals =
  match Queue.pop domain.blocks with
  | Rd { cancelled= true; _ } | Wr { cancelled= true; _ } ->
      consume_block domain signals
  | Rd { t; bstr; off; syscall; _ } ->
      Block.unsafe_read t ~off bstr;
      Miou.signal syscall :: signals
  | Wr { t; bstr; off; syscall; _ } ->
      Block.unsafe_write t ~off bstr;
      Miou.signal syscall :: signals

let clean domain uids =
  let to_keep syscall =
    let uid = Miou.uid syscall in
    List.exists (fun uid' -> uid != uid') uids
  in
  let fn0 (handle, syscalls) =
    match List.filter to_keep syscalls with
    | [] -> None
    | syscalls -> Some (handle, syscalls)
  in
  let fn1 (({ syscall; _ } : elt) as elt) =
    if not (to_keep syscall) then elt.cancelled <- true
  in
  let fn2 = function
    | Rd ({ syscall; _ } as elt) | Wr ({ syscall; _ } as elt) ->
        if not (to_keep syscall) then elt.cancelled <- true
  in
  Handles.filter_map fn0 domain.handles;
  Heapq.iter fn1 domain.sleepers;
  Queue.iter fn2 domain.blocks

external miou_solo5_yield : (int[@untagged]) -> (int[@untagged])
  = "unimplemented" "miou_solo5_yield"
[@@noalloc]

type waiting = Infinity | Yield | Sleep

let wait_for ~block domain =
  match (sleeper domain, block) with
  | None, true -> Infinity
  | (None | Some _), false -> Yield
  | Some point, true ->
      let until = point - clock_monotonic () in
      if until < 0 then Yield else Sleep

(* The behaviour of our select is a little different from what we're used to
   seeing. Currently, only a read on a net device can produce a necessary
   suspension (the reception of packets on the network).

   However, a special case concerns the block device. Reading and writing to it
   can take time. It can be interesting to suspend these actions and actually
   do them when we should be waiting (as long as a sleeper is active or until
   an event appears).

   The idea is to suspend these actions so that we can take the opportunity to
   do something else and actually do them when we have the time to do so: when
   Miou has no more tasks to do and when we don't have any network events to
   manage.

   The implication of this would be that our unikernels would be limited by I/O
   on block devices. They won't be able to go any further than reading and
   writing to block devices. As far as I/O on net devices is concerned, we are
   only limited by the OCaml code that has to handle incoming packets. Packet
   writing, on the other hand, is direct. *)

let select ~block cancelled_syscalls =
  let domain = domain () in
  clean domain cancelled_syscalls;
  let handles = ref 0 in
  let rec go signals =
    match wait_for ~block domain with
    | Infinity ->
        (* Miou tells us we can wait forever ([block = true]) and we have no
           sleepers. So we're going to: take action on the block devices and ask
           Solo5 if we need to manage an event. If we have an event after the
           action on the block device ([handles != 0]), we stop and send the
           signals to Miou. If not, we take the opportunity to possibly go
           further. *)
        let signals = consume_block domain signals in
        handles := miou_solo5_yield 0;
        if !handles == 0 then go signals else signals
    | Yield ->
        (* Miou still has work to do but asks if there are any events. We ask
           Solo5 if there are any and return the possible signals to Miou. *)
        handles := miou_solo5_yield 0;
        signals
    | Sleep ->
        (* We have a sleeper that is still active and will have to wait a while
           before consuming it. In the meantime, we take action on the block
           devices and repeat our [select] if Solo5 tells us that there are no
           events ([handle == 0]). *)
        let signals = consume_block domain signals in
        handles := miou_solo5_yield 0;
        if !handles == 0 then go signals else signals
  in
  let signals = go [] in
  let signals = collect_handles ~handles:!handles domain signals in
  collect_sleepers domain signals

let events _domain = { Miou.interrupt= ignore; select; finaliser= ignore }
let run ?g fn = Miou.run ~events ?g ~domains:0 fn