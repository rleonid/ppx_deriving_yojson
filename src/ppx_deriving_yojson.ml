open Longident
open Location
open Asttypes
open Parsetree
open Ast_helper
open Ast_convenience

let prefix = "yojson"
let raise_errorf = Ppx_deriving.raise_errorf

let argn = Printf.sprintf "arg%d"

let attr_int_encoding typ =
  match Ppx_deriving.attr ~prefix "encoding" typ.ptyp_attributes |>
        Ppx_deriving.Arg.(payload ~name:"Yojson" (enum ["string"; "number"])) with
  | Some "string" -> `String
  | Some "number" | None -> `Int
  | _ -> assert false

let attr_key default attrs =
  match Ppx_deriving.attr ~prefix "key" attrs |>
        Ppx_deriving.Arg.(payload ~name:"Yojson" string) with
  | Some x -> x
  | None   -> default

let rec ser_expr_of_typ typ =
  let attr_int_encoding typ =
    match attr_int_encoding typ with `String -> "String" | `Int -> "Intlit"
  in
  match typ with
  | [%type: int]             -> [%expr fun x -> `Int x]
  | [%type: float]           -> [%expr fun x -> `Float x]
  | [%type: bool]            -> [%expr fun x -> `Bool x]
  | [%type: string]          -> [%expr fun x -> `String x]
  | [%type: bytes]           -> [%expr fun x -> `String (Bytes.to_string x)]
  | [%type: char]            -> [%expr fun x -> `String (String.make 1 x)]
  | [%type: [%t? typ] ref]   -> [%expr fun x -> [%e ser_expr_of_typ typ] !x]
  | [%type: [%t? typ] list]  -> [%expr fun x -> `List (List.map [%e ser_expr_of_typ typ] x)]
  | [%type: int32] | [%type: Int32.t] ->
    [%expr fun x -> `Intlit (Int32.to_string x)]
  | [%type: int64] | [%type: Int64.t] ->
    [%expr fun x -> [%e Exp.variant (attr_int_encoding typ)
                                    (Some [%expr (Int64.to_string x)])]]
  | [%type: nativeint] | [%type: Nativeint.t] ->
    [%expr fun x -> [%e Exp.variant (attr_int_encoding typ)
                                    (Some [%expr (Nativeint.to_string x)])]]
  | [%type: [%t? typ] array] ->
    [%expr fun x -> `List (Array.to_list (Array.map [%e ser_expr_of_typ typ] x))]
  | [%type: [%t? typ] option] ->
    [%expr function None -> `Null | Some x -> [%e ser_expr_of_typ typ] x]
  | { ptyp_desc = Ptyp_constr ({ txt = lid }, args) } ->
    app (Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Suffix "to_yojson") lid)))
        (List.map ser_expr_of_typ args)
  | { ptyp_desc = Ptyp_tuple typs } ->
    [%expr fun [%p ptuple (List.mapi (fun i _ -> pvar (argn i)) typs)] ->
      `List ([%e
        list (List.mapi (fun i typ -> app (ser_expr_of_typ typ) [evar (argn i)]) typs)])];
  | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
    let cases =
      fields |> List.map (fun field ->
        match field with
        | Rtag (label, _, true (*empty*), []) ->
          Exp.case (Pat.variant label None)
                   [%expr `List [`String [%e str label]]]
        | Rtag (label, _, false, [{ ptyp_desc = Ptyp_tuple typs }]) ->
          Exp.case (Pat.variant label (Some (ptuple (List.mapi (fun i _ -> pvar (argn i)) typs))))
                   [%expr `List ((`String [%e str label]) :: [%e
                      list (List.mapi
                        (fun i typ -> app (ser_expr_of_typ typ) [evar (argn i)]) typs)])]
        | Rtag (label, _, false, [typ]) ->
          Exp.case (Pat.variant label (Some [%pat? x]))
                   [%expr `List [`String [%e str label]; [%e ser_expr_of_typ typ] x]]
        | Rinherit ({ ptyp_desc = Ptyp_constr (tname, []) } as typ) ->
          Exp.case [%pat? [%p Pat.type_ tname] as x]
                   [%expr [%e ser_expr_of_typ typ] x]
        | _ ->
          raise_errorf ~loc:ptyp_loc "Cannot derive Yojson for %s"
                       (Ppx_deriving.string_of_core_type typ))
    in
    Exp.function_ cases
  | { ptyp_desc = Ptyp_var name } -> [%expr ([%e evar ("poly_"^name)] : 'a -> Yojson.Safe.json)]
  | { ptyp_desc = Ptyp_alias (typ, name) } ->
    [%expr fun x -> [%e evar ("poly_"^name)] x; [%e ser_expr_of_typ typ] x]
  | { ptyp_loc } ->
    raise_errorf ~loc:ptyp_loc "Cannot derive Yojson for %s"
                 (Ppx_deriving.string_of_core_type typ)

(* http://desuchan.net/desu/src/1284751839295.jpg *)
let rec desu_fold ~path f typs =
  typs |>
  List.mapi (fun i typ -> i, app (desu_expr_of_typ ~path typ) [evar (argn i)]) |>
  List.fold_left (fun x (i, y) ->
    [%expr [%e y] >>= fun [%p pvar (argn i)] -> [%e x]])
    [%expr `Ok [%e f (List.mapi (fun i _ -> evar (argn i)) typs)]]
and desu_expr_of_typ ~path typ =
  let error = [%expr `Error [%e str (String.concat "." path)]] in
  let decode' cases =
    Exp.function_ (
      List.map (fun (pat, exp) -> Exp.case pat exp) cases @
      [Exp.case [%pat? _] error])
  in
  let decode pat exp = decode' [pat, exp] in
  match typ with
  | [%type: int]    -> decode [%pat? `Int x]    [%expr `Ok x]
  | [%type: float]  -> decode [%pat? `Float x]  [%expr `Ok x]
  | [%type: bool]   -> decode [%pat? `Bool x]   [%expr `Ok x]
  | [%type: string] -> decode [%pat? `String x] [%expr `Ok x]
  | [%type: bytes]  -> decode [%pat? `String x] [%expr `Ok (Bytes.of_string x)]
  | [%type: char]   ->
    decode [%pat? `String x] [%expr if String.length x = 1 then `Ok x.[0] else [%e error]]
  | [%type: int32] | [%type: Int32.t] ->
    decode' [[%pat? `Int x],    [%expr `Ok (Int32.of_int x)];
             [%pat? `Intlit x], [%expr `Ok (Int32.of_string x)]]
  | [%type: int64] | [%type: Int64.t] ->
    begin match attr_int_encoding typ with
    | `String ->
      decode [%pat? `String x] [%expr `Ok (Int64.of_string x)]
    | `Int ->
      decode' [[%pat? `Int x],    [%expr `Ok (Int64.of_int x)];
               [%pat? `Intlit x], [%expr `Ok (Int64.of_string x)]]
    end
  | [%type: nativeint] | [%type: Nativeint.t] ->
    begin match attr_int_encoding typ with
    | `String ->
      decode [%pat? `String x] [%expr `Ok (Nativeint.of_string x)]
    | `Int ->
      decode' [[%pat? `Int x],    [%expr `Ok (Nativeint.of_int x)];
               [%pat? `Intlit x], [%expr `Ok (Nativeint.of_string x)]]
    end
  | [%type: [%t? typ] ref]   ->
    [%expr fun x -> [%e desu_expr_of_typ ~path:(path @ ["contents"]) typ] x >|= ref]
  | [%type: [%t? typ] option] ->
    [%expr function
           | `Null -> `Ok None
           | x     -> [%e desu_expr_of_typ ~path typ] x >>= fun x -> `Ok (Some x)]
  | [%type: [%t? typ] list]  ->
    decode [%pat? `List xs]
           [%expr map_bind [%e desu_expr_of_typ ~path typ] [] xs]
  | [%type: [%t? typ] array] ->
    decode [%pat? `List xs]
           [%expr map_bind [%e desu_expr_of_typ ~path typ] [] xs >|= Array.of_list]
  | { ptyp_desc = Ptyp_tuple typs } ->
    decode [%pat? `List [%p plist (List.mapi (fun i _ -> pvar (argn i)) typs)]]
           (desu_fold ~path tuple typs)
  | { ptyp_desc = Ptyp_variant (fields, _, _); ptyp_loc } ->
    let cases =
      List.map (fun field ->
        match field with
        | Rtag (label, _, true (*empty*), []) ->
          Exp.case [%pat? `List [`String [%p pstr label]]]
                   [%expr `Ok [%e Exp.variant label None]]
        | Rtag (label, _, false, [{ ptyp_desc = Ptyp_tuple typs }]) ->
          Exp.case [%pat? `List ((`String [%p pstr label]) :: [%p
                      plist (List.mapi (fun i _ -> pvar (argn i)) typs)])]
                   (desu_fold ~path (fun x -> (Exp.variant label (Some (tuple x)))) typs)
        | Rtag (label, _, false, [typ]) ->
          Exp.case [%pat? `List [`String [%p pstr label]; x]]
                   [%expr [%e desu_expr_of_typ ~path typ] x >>= fun x ->
                          `Ok [%e Exp.variant label (Some [%expr x])]]
        | Rinherit ({ ptyp_desc = Ptyp_constr (tname, []) } as typ) ->
          Exp.case [%pat? [%p Pat.type_ tname] as x]
                   [%expr [%e desu_expr_of_typ ~path typ] x]
        | _ ->
          raise_errorf ~loc:ptyp_loc "Cannot derive Yojson for %s"
                       (Ppx_deriving.string_of_core_type typ)) fields @
      [Exp.case [%pat? _] error]
    in
    [%expr fun (json : Yojson.Safe.json) -> [%e Exp.match_ [%expr json] cases]]
  | { ptyp_desc = Ptyp_constr ({ txt = lid }, args) } ->
    app (Exp.ident (mknoloc (Ppx_deriving.mangle_lid (`Suffix "of_yojson") lid)))
        (List.map (desu_expr_of_typ ~path) args)
  | { ptyp_desc = Ptyp_var name } ->
    [%expr ([%e evar ("poly_"^name)] : Yojson.Safe.json -> [ `Ok of 'a | `Error of string ])]
  | { ptyp_desc = Ptyp_alias (typ, name) } ->
    [%expr fun x -> [%e evar ("poly_"^name)] x; [%e desu_expr_of_typ ~path typ] x]
  | { ptyp_loc } ->
    raise_errorf ~loc:ptyp_loc "Cannot derive Yojson for %s"
                 (Ppx_deriving.string_of_core_type typ)

let str_of_type ~options ~path ({ ptype_loc = loc } as type_decl) =
  let path = path @ [type_decl.ptype_name.txt] in
  let wrap_decls decls = [%expr
    (let (>>=) x f = match x with `Ok x -> f x | (`Error _) as x -> x in
     let (>|=) x f = x >>= fun x -> `Ok (f x) in
     let rec map_bind f acc xs =
       match xs with x :: xs -> f x >>= fun x -> map_bind f (x :: acc) xs | [] -> `Ok acc
     in [%e decls]) [@ocaml.warning "-26"]] in
  let error = [%expr `Error [%e str (String.concat "." path)]] in
  let serializer, desurializer =
    match type_decl.ptype_kind, type_decl.ptype_manifest with
    | Ptype_abstract, Some manifest ->
      ser_expr_of_typ manifest, wrap_decls (desu_expr_of_typ ~path manifest)
    | Ptype_variant constrs, _ ->
      (* ser *)
      constrs |>
      List.map (fun { pcd_name = { txt = name' }; pcd_args } ->
        let args = List.mapi (fun i typ -> app (ser_expr_of_typ typ) [evar (argn i)]) pcd_args in
        let result =
          match args with
          | []   -> [%expr `List [`String [%e str name']]]
          | args -> [%expr `List ((`String [%e str name']) :: [%e list args])]
        in
        Exp.case (pconstr name' (List.mapi (fun i _ -> pvar (argn i)) pcd_args)) result) |>
      Exp.function_,
      (* desu *)
      List.map (fun { pcd_name = { txt = name' }; pcd_args } ->
        Exp.case [%pat? `List ((`String [%p pstr name']) ::
                          [%p plist (List.mapi (fun i _ -> pvar (argn i)) pcd_args)])]
                 (desu_fold ~path (fun x -> constr name' x) pcd_args)) constrs @
      [Exp.case [%pat? _] error] |>
      Exp.function_ |>
      wrap_decls
    | Ptype_record labels, _ ->
      (* ser *)
      labels |>
      List.mapi (fun i { pld_name = { txt = name }; pld_type; pld_attributes } ->
        [%expr [%e str (attr_key name pld_attributes)],
               [%e ser_expr_of_typ pld_type] [%e Exp.field (evar "x") (mknoloc (Lident name))]]) |>
      fun fields -> [%expr fun x -> `Assoc [%e list fields]],
      (* desu *)
      let typs   = List.map (fun { pld_type } -> pld_type) labels in
      let record =
        desu_fold ~path (fun xs ->
          Exp.record (List.map2 (fun { pld_name = { txt = name } } x ->
            (mknoloc (Lident name)), x) labels xs) None) typs
      in
      [%expr
        function
        | `Assoc xs ->
          begin try
            let [%p ptuple (List.mapi (fun i _ -> pvar (argn i)) labels)] =
              [%e tuple (List.mapi (fun i { pld_name = { txt = name }; pld_attributes } ->
                    [%expr List.assoc [%e str (attr_key name pld_attributes)] xs]) labels)] in
            if List.length xs = [%e int (List.length labels)] then
              [%e record]
            else
              [%e error]
          with Not_found ->
            [%e error]
          end
        | _ -> [%e error]] |>
      wrap_decls
    | Ptype_abstract, None -> raise_errorf ~loc "Cannot derive Yojson for fully abstract type"
    | Ptype_open, _        -> raise_errorf ~loc "Cannot derive Yojson for open type"
  in
  let polymorphize = Ppx_deriving.poly_fun_of_type_decl type_decl in
  [Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Suffix "to_yojson") type_decl))
               (polymorphize [%expr ([%e serializer] : _ -> Yojson.Safe.json)]);
   Vb.mk (pvar (Ppx_deriving.mangle_type_decl (`Suffix "of_yojson") type_decl))
               (polymorphize [%expr ([%e desurializer] : Yojson.Safe.json -> _)])]

let sig_of_type ~options ~path type_decl =
  let typ = Ppx_deriving.core_type_of_type_decl type_decl in
  let error_or typ = [%type: [ `Ok of [%t typ] | `Error of string ]] in
  let polymorphize_ser  = Ppx_deriving.poly_arrow_of_type_decl
                            (fun var -> [%type: [%t var] -> Yojson.Safe.json]) type_decl
  and polymorphize_desu = Ppx_deriving.poly_arrow_of_type_decl
                            (fun var -> [%type: Yojson.Safe.json -> [%t error_or var]]) type_decl in
  [Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Suffix "to_yojson") type_decl))
              (polymorphize_ser  [%type: [%t typ] -> Yojson.Safe.json]));
   Sig.value (Val.mk (mknoloc (Ppx_deriving.mangle_type_decl (`Suffix "of_yojson") type_decl))
              (polymorphize_desu [%type: Yojson.Safe.json -> [%t error_or typ]]))]

let () =
  Ppx_deriving.(register "Yojson" {
    core_type = (fun { ptyp_loc } ->
      raise_errorf ~loc:ptyp_loc "[%%derive.Yojson] is not supported");
    structure = (fun ~options ~path type_decls ->
      [Str.value Recursive (List.concat (List.map (str_of_type ~options ~path) type_decls))]);
    signature = (fun ~options ~path type_decls ->
      List.concat (List.map (sig_of_type ~options ~path) type_decls));
  })
