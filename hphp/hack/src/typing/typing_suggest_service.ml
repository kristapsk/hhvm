(**
 * Copyright (c) 2015, Facebook, Inc.
 * All rights reserved.
 *
 * This source code is licensed under the BSD-style license found in the
 * LICENSE file in the "hack" directory of this source tree. An additional grant
 * of patent rights can be found in the PATENTS file in the same directory.
 *
 *)

(*****************************************************************************)
(* This module implements a global type inference scheme to automatically
 * annotate Hack code with missing type hints.
 *)
(*****************************************************************************)

open Core

module Env = Typing_env
module SN = Naming_special_names

let insert_resolved_result fn acc result =
  let pl = try Relative_path.Map.find_unsafe acc fn with Not_found -> [] in
  let pl = result :: pl in
  Relative_path.Map.add acc ~key:fn ~data:pl

let merge_resolved_result x y =
  Relative_path.Map.fold x ~init:y ~f:begin fun k vs acc ->
    List.fold_left vs ~f:(insert_resolved_result k) ~init:acc
  end

(* Given a hash table as generated by collate_types, look at each position in
 * the code and try to find a type that matches all the suggestions recorded
 * there. *)
let resolve_types tcopt acc collated_values =
  let patches = ref acc in
  (* Time out a particular location after 60 seconds and move on. While you are
   * unlikely to hit this unless you are running over all of Facebook's code
   * all at once, but doing that is useful so let's make it not take half an
   * hour on a beefy machine to resolve all the types. *)
  let t = 60 in
  List.iter collated_values begin fun ((fn, line, kind), envl_tyl) ->
  Timeout.with_timeout
    ~timeout:t
    ~on_timeout:(fun () -> raise Timeout.Timeout)
    ~do_:begin fun t ->
    let open Timeout in
    let env = Env.empty tcopt fn ~droot:None in
    let env, tyl = List.fold_right ~f:begin fun (env, ty) (env_acc, tyl) ->
      (* This is a pretty hacky environment merge, potentially merging envs from
       * completely separate contexts. It relies on type variables being
       * globally unique over runs of the program, later types being prepended
       * to the type list (hence fold_right), and union overwriting mappings in
       * its second argument with those in its first argument (so we get the
       * most up-to-date mappings at the end of the day). And hey, even if this
       * isn't 100% sound, if we screw it up we will just skip a suggestion we
       * otherwise could have made, not the end of the world. *)
      (* Extra check on Windows to check to see if Timeout is reached.
         On Linux, nothing is done, see Timeout module. *)
      check_timeout t;
      let merged_tenv = IMap.union env.Env.tenv env_acc.Env.tenv in
      let merged_subst = IMap.union env.Env.subst env_acc.Env.subst in
      {env_acc with Env.tenv = merged_tenv; Env.subst = merged_subst}, ty::tyl
    end ~init:(env, []) envl_tyl in
    let reason = Typing_reason.Rnone in
    let ureason = Typing_reason.URnone in
    let any = reason, Typing_defs.Tany in
    let strip_dependent_types ty =
      match snd ty with
      | Typing_defs.Tabstract (
          Typing_defs.AKdependent (`cls _, []), Some ty
        ) -> ty
      | _ -> ty in
    let tyl = List.map tyl strip_dependent_types in
    let env, type_ =
      try
        Errors.try_ begin fun () ->
          let unify (env, ty1) ty2 =
            Typing_ops.unify Pos.none ureason env ty1 ty2 in
          List.fold_left tyl ~f:unify ~init:(env, any)
        end (fun _ -> raise Exit)
      with Timeout -> raise Timeout | _ -> try Errors.try_ begin fun () ->
        let sub ty1 env ty2 =
          Typing_ops.sub_type Pos.none ureason env ty2 ty1 in

        (* Check a list of types, left to right, returning the first one that is
         * a supertype of tyl, or raising Not_found if none are suitable.
         *)
        let rec guess_super env tyl = function
          | [] -> raise Not_found
          | guess :: guesses ->
            (* Extra check on Windows to check to see if Timeout is reached. *)
            check_timeout t;
            try
              Errors.try_ begin fun () ->
                List.fold_left tyl ~f:(sub guess) ~init:env, guess
              end (fun _ -> raise Exit)
            with Timeout -> raise Timeout | _ -> guess_super env tyl guesses in

        let xhp = reason, Typing_defs.Tclass ((Pos.none, "\\:xhp"), []) in
        let xhp_option = reason, Typing_defs.Toption xhp in
        let awaitable ty =
          reason, Typing_defs.Tclass ((Pos.none, SN.Classes.cAwaitable), [ty]) in
        let awaitable_xhp = awaitable xhp in
        let awaitable_xhp_option = awaitable xhp_option in

        let guesses =
          (* See if they are specifically using some subclass of an XHP element.
           * This might seem like an oddly specific special case but it comes up
           * all the time in www:
           *
           * function f() {
           *   if ($cond) {
           *     return <div />;
           *   } else {
           *     return <span />;
           *   }
           *)
          xhp::
          awaitable_xhp::
          xhp_option::
          awaitable_xhp_option::

          (* Maybe one of the types in the list will be a suitable supertype. *)
          tyl
        in
        guess_super env tyl guesses
        end (fun _ -> raise Exit)
      with Timeout -> raise Timeout | _ ->
        env, any
    in
    (* We don't suggest shape type hints yet, so downgrading all
     * shape-like arrays to plain arrays. *)
    let type_ = Typing_arrays.fully_expand_tvars_downcast_aktypes env type_ in
    (* XXX should probably use the real .hhconfig-based tcopt to lazy decl to
     * be correct in incremental mode, but --convert is not really maintained
     * anyway and precludes incremental mode *)
    match Typing_suggest.normalize tcopt type_ with
    | None -> ()
    | Some ty ->
        patches := (insert_resolved_result fn !patches (line, kind, ty))
  end end;
  !patches

let hashtbl_keys tbl =
  let tmp_tbl = Hashtbl.create (Hashtbl.length tbl) in
  Hashtbl.iter begin fun k _ ->
    if not (Hashtbl.mem tmp_tbl k) then Hashtbl.add tmp_tbl k ();
  end tbl;
  Hashtbl.fold (fun k () acc -> k::acc) tmp_tbl []

let hashtbl_all_values tbl =
  let keys = hashtbl_keys tbl in
  List.fold_left keys
    ~f:(fun acc key -> (key, Hashtbl.find_all tbl key) :: acc) ~init:[]

let parallel_resolve_types workers collated tcopt =
  (* TODO jwatzman #2910120 this scheme is still pretty dumb but at least kinda
   * sorta works on medium-sized examples. Should make it scale all the way. *)
  let values = hashtbl_all_values collated in
  Hashtbl.clear collated;
  let result =
    MultiWorker.call
      workers
      ~job:(resolve_types tcopt)
      ~neutral:Relative_path.Map.empty
      ~merge:merge_resolved_result
      ~next:(MultiWorker.next workers values)
  in
  result

(* Take a list of all the computed type suggestions and collate them by file,
 * line, and type kind -- basically get things into a state where we can look
 * at all the positions in the code where we have a suggestion and unify across
 * all the suggestions to see if we can find something that works. *)
let collate_types fast all_types =
  let tbl = Hashtbl.create (Relative_path.Map.cardinal fast) in
  List.iter all_types begin fun (env, pos, k, ty) ->
    let fn = Pos.filename pos in
    let line, _, _ = Pos.info_pos pos in
    (* Discard patches from files we aren't concerned about. This can happen if
     * a file we do care about calls a function in a file we don't, causing us
     * to infer a parameter type in the target file. *)
    if Relative_path.Map.mem fast fn
    then Hashtbl.add tbl (fn, line, k) (env, ty);
  end;
  tbl

let keys map = Relative_path.Map.fold map ~init:[] ~f:(fun x _ y -> x :: y)

(* Typecheck a part of the codebase, in order to record the type suggestions in
 * Type_suggest.types. *)
let suggest_files tcopt fnl =
  SharedMem.invalidate_caches();
  Typing_defs.is_suggest_mode := true;
  Typing_suggest.types := [];
  Typing_suggest.initialized_members := SMap.empty;
  List.iter fnl begin fun fn ->
    let tcopt = TypecheckerOptions.make_permissive tcopt in
    match Parser_heap.ParserHeap.get fn with
    | Some (ast, _) ->
      let nast = Naming.program tcopt ast in
      List.iter nast begin function
        | Nast.Fun f -> ignore (Typing.fun_def tcopt f)
        | Nast.Class c -> Typing.class_def tcopt c
        | _ -> ()
      end
    | None -> ()
  end;
  let result = !Typing_suggest.types in
  Typing_defs.is_suggest_mode := false;
  Typing_suggest.types := [];
  Typing_suggest.initialized_members := SMap.empty;
  result

let suggest_files_worker tcopt acc fnl  =
  let types = suggest_files tcopt fnl  in
  List.rev_append types acc

let parallel_suggest_files workers fast tcopt =
  let fnl = keys fast in
  let result =
    MultiWorker.call
      workers
      ~job:(suggest_files_worker tcopt)
      ~neutral:[]
      ~merge:(List.rev_append)
      ~next:(MultiWorker.next workers fnl)
  in
  result

(*****************************************************************************)
(* Let's go! That's where the action is *)
(*****************************************************************************)

let go workers fast tcopt =
  let trace = !Typing_deps.trace in
  Typing_deps.trace := false;
  let types =
    match workers with
    | Some _ -> parallel_suggest_files workers fast tcopt
    | None -> suggest_files tcopt (keys fast) in
  let collated = collate_types fast types in
  let resolved =
    match workers with
    | Some _ -> parallel_resolve_types workers collated tcopt
    | None ->
      resolve_types tcopt Relative_path.Map.empty (hashtbl_all_values collated)
  in
  Typing_deps.trace := trace;
  resolved
