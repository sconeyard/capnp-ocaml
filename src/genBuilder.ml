(******************************************************************************
 * capnp-ocaml
 *
 * Copyright (c) 2013-2014, Paul Pelzl
 * All rights reserved.
 *
 * Redistribution and use in source and binary forms, with or without
 * modification, are permitted provided that the following conditions are met:
 *
 *  1. Redistributions of source code must retain the above copyright notice,
 *     this list of conditions and the following disclaimer.
 *
 *  2. Redistributions in binary form must reproduce the above copyright
 *     notice, this list of conditions and the following disclaimer in the
 *     documentation and/or other materials provided with the distribution.
 *
 * THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS"
 * AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE
 * IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE
 * ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDER OR CONTRIBUTORS BE
 * LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
 * CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
 * SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
 * INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
 * CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
 * ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 ******************************************************************************)


open Core.Std

module PS = GenCommon.PS
module Mode = GenCommon.Mode
module R  = Runtime
module Builder = MessageBuilder.Make(GenCommon.M)

let sprintf = Printf.sprintf

(* Generate an encoder lambda for converting from an enum value to the associated
   uint16.  [allow_undefined] indicates whether or not to permit enum values which
   use the [Undefined_] constructor. *)
let generate_enum_encoder ~(allow_undefined : bool) ~nodes_table ~scope
    ~enum_node ~indent ~field_ofs =
  let header = sprintf "%s(fun enum -> match enum with\n" indent in
  let match_cases =
    let scope_relative_name =
      GenCommon.get_scope_relative_name nodes_table scope enum_node
    in
    let enumerants =
      match PS.Node.unnamed_union_get enum_node with
      | PS.Node.Enum enum_group ->
          PS.Node.Enum.enumerants_get enum_group
      | _ ->
          failwith "Decoded non-enum node where enum node was expected."
    in
    let buf = Buffer.create 512 in
    for i = 0 to R.Array.length enumerants - 1 do
      let enumerant = R.Array.get enumerants i in
      let match_case =
        sprintf "%s  | %s.%s -> %u\n"
          indent
          scope_relative_name
          (String.capitalize (PS.Enumerant.name_get enumerant))
          i
      in
      Buffer.add_string buf match_case
    done;
    let footer =
      if allow_undefined then
        sprintf "%s  | %s.Undefined_ x -> x\n)" indent scope_relative_name
      else
        String.concat ~sep:"" [
          sprintf "%s  | %s.Undefined_ _ ->\n" indent scope_relative_name;
          sprintf
            "%s      raise \
             (Invalid_message \"Cannot encode undefined enum value.\"))\n"
            indent;
        ]
    in
    let () = Buffer.add_string buf footer in
    Buffer.contents buf
  in
  header ^ match_cases


(* Generate an accessor for decoding an enum type. *)
let generate_enum_getter ~nodes_table ~scope ~enum_node ~indent ~field_name
    ~field_ofs ~default =
  let decoder_declaration =
    sprintf "%s  let decode =\n%s%s  in\n"
      indent
      (GenReader.generate_enum_decoder ~nodes_table ~scope ~enum_node
         ~indent:(indent ^ "    ") ~field_ofs)
      indent
  in
  sprintf
    "%slet %s_get x =\n%s%s  decode (get_struct_field_uint16 ~default:%u x %u)\n"
    indent
    field_name
    decoder_declaration
    indent
    default
    (2 * field_ofs)


(* Generate an accessor for setting the value of an enum. *)
let generate_enum_safe_setter ~nodes_table ~scope ~enum_node ~indent ~field_name
    ~field_ofs ~default ~discr_str =
  let encoder_declaration =
    sprintf "%s  let encode =\n%s%s  in\n"
      indent
      (generate_enum_encoder ~allow_undefined:false ~nodes_table ~scope ~enum_node
         ~indent:(indent ^ "    ") ~field_ofs)
      indent
  in
  sprintf
    "%slet %s_set x e =\n%s%s  \
     set_struct_field_uint16 %s~default:%u x %u (encode e)\n"
    indent
    field_name
    encoder_declaration
    indent
    discr_str
    default
    (2 * field_ofs)


(* Generate an accessor for setting the value of an enum, permitting values
   which are not defined in the schema. *)
let generate_enum_unsafe_setter ~nodes_table ~scope ~enum_node ~indent
    ~field_name ~field_ofs ~default ~discr_str =
  let encoder_declaration =
    sprintf "%s  let encode =\n%s%s  in\n"
      indent
      (generate_enum_encoder ~allow_undefined:true ~nodes_table ~scope ~enum_node
         ~indent:(indent ^ "    ") ~field_ofs)
      indent
  in
  sprintf
    "%slet %s_set_unsafe x e =\n%s%s  \
     set_struct_field_uint16 %s~default:%u x %u (encode e)\n"
    indent
    field_name
    encoder_declaration
    indent
    discr_str
    default
    (2 * field_ofs)


(* Generate an accessor for retrieving a list of the given type. *)
let generate_list_accessor ~nodes_table ~scope ~list_type ~indent
    ~field_name ~field_ofs ~discr_str =
  let make_accessors type_str =
    (sprintf "%slet %s_get x = get_struct_field_%s_list x %u\n"
      indent
      field_name
      type_str
      field_ofs) ^
    (sprintf "%slet %s_set x v = set_struct_field_%s_list \
              %sx %u v\n"
      indent
      field_name
      type_str
      discr_str
      field_ofs) ^
    (sprintf "%slet %s_init x n = init_struct_field_%s_list \
              %sx %u ~num_elements:n"
      indent
      field_name
      type_str
      discr_str
      field_ofs)
  in
  match PS.Type.unnamed_union_get list_type with
  | PS.Type.Void ->
      (sprintf "%slet %s_get x = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_set x v = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_init x n = failwith \"not implemented\"\n"
        indent
        field_name)
  | PS.Type.Bool ->
      make_accessors "bit"
  | PS.Type.Int8 ->
      make_accessors "int8"
  | PS.Type.Int16 ->
      make_accessors "int16"
  | PS.Type.Int32 ->
      make_accessors "int32"
  | PS.Type.Int64 ->
      make_accessors "int64"
  | PS.Type.Uint8 ->
      make_accessors "uint8"
  | PS.Type.Uint16 ->
      make_accessors "uint16"
  | PS.Type.Uint32 ->
      make_accessors "uint32"
  | PS.Type.Uint64 ->
      make_accessors "uint64"
  | PS.Type.Float32 ->
      make_accessors "float32"
  | PS.Type.Float64 ->
      make_accessors "float64"
  | PS.Type.Text ->
      make_accessors "text"
  | PS.Type.Data ->
      make_accessors "blob"
  | PS.Type.List _ ->
      make_accessors "list"
  | PS.Type.Enum enum_def ->
      let enum_id = PS.Type.Enum.typeId_get enum_def in
      let enum_node = Hashtbl.find_exn nodes_table enum_id in
      let decoder_declaration =
        sprintf "%s  let decode =\n%s%s  in\n"
          indent
          (GenReader.generate_enum_decoder ~nodes_table ~scope ~enum_node
            ~indent:(indent ^ "    ") ~field_ofs)
          indent
      in
      let encoder_declaration =
        sprintf "%s  let encode =\n%s%s  in\n"
          indent
          (generate_enum_encoder ~allow_undefined:false ~nodes_table ~scope
             ~enum_node ~indent:(indent ^ "    ") ~field_ofs)
          indent
      in
      (sprintf "%slet %s_get x =\n%s%s\
                %s  get_struct_field_enum_list x %u ~decode ~encode\n"
        indent
        field_name
        decoder_declaration
        encoder_declaration
        indent
        (field_ofs * 2)) ^
      (sprintf "%slet %s_set x v =\n%s%s\
                %s  set_struct_field_enum_list %sx %u v ~decode ~encode\n"
        indent
        field_name
        decoder_declaration
        encoder_declaration
        indent
        discr_str
        (field_ofs * 2)) ^
      (sprintf "%slet %s_init x n =\n%s%s\
                %s  init_struct_field_enum_list %sx %u ~decode ~encode ~num_elements:n\n"
        indent
        field_name
        decoder_declaration
        encoder_declaration
        indent
        discr_str
        (field_ofs * 2))
  | PS.Type.Struct struct_def ->
      let id = PS.Type.Struct.typeId_get struct_def in
      let node = Hashtbl.find_exn nodes_table id in
      begin match PS.Node.unnamed_union_get node with
      | PS.Node.Struct struct_def' ->
          let data_words    = PS.Node.Struct.dataWordCount_get struct_def' in
          let pointer_words = PS.Node.Struct.pointerCount_get struct_def' in
          (sprintf
            "%slet %s_get x = get_struct_field_struct_list x %u \
             ~data_words:%u ~pointer_words:%u\n"
            indent
            field_name
            field_ofs
            data_words
            pointer_words) ^
          (sprintf
             "%slet %s_set x v = set_struct_field_struct_list %sx %u v \
              ~data_words:%u ~pointer_words:%u\n"
            indent
            field_name
            discr_str
            field_ofs
            data_words
            pointer_words) ^
          (sprintf
             "%slet %s_init x n = init_struct_field_struct_list %sx %u \
              ~data_words:%u ~pointer_words:%u ~num_elements:n\n"
            indent
            field_name
            discr_str
            field_ofs
            data_words
            pointer_words)
      | _ ->
          failwith "decoded non-struct node where struct node was expected."
      end
  | PS.Type.Interface _ ->
      (sprintf "%slet %s_get x = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_set x v = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_init x n = failwith \"not implemented\"\n"
        indent
        field_name)
  | PS.Type.AnyPointer ->
      (sprintf "%slet %s_get x = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_set x v = failwith \"not implemented\"\n"
        indent
        field_name) ^
      (sprintf "%slet %s_init x n = failwith \"not implemented\"\n"
        indent
        field_name)
  | PS.Type.Undefined_ x ->
       failwith (sprintf "Unknown Type union discriminant %d" x)


(* FIXME: would be nice to unify default value logic with [generate_constant]... *)
let generate_field_accessors ~nodes_table ~scope ~indent ~discr_ofs field =
  let field_name = String.uncapitalize (PS.Field.name_get field) in
  let discr_str =
    let discriminant_value = PS.Field.discriminantValue_get field in
    if discriminant_value = PS.Field.noDiscriminant then
      ""
    else
      sprintf "~discr:{Discr.value=%u, Discr.byte_ofs=%u} "
        discriminant_value (discr_ofs * 2)
  in
  match PS.Field.unnamed_union_get field with
  | PS.Field.Group group ->
      (sprintf "%slet %s_get x = x\n"
        indent
        field_name) ^
        (* So group setters look unexpectedly complicated.  [x] is the parent struct
         * which contains the group to be modified, and [v] is another struct which
         * contains the group with values to be copied.  The resulting operation
         * should merge the group fields from [v] into the proper place in struct [x]. *)
      (sprintf "%slet %s_set x v = failwith \"not implemented\"\n"
         indent
         field_name)
  | PS.Field.Slot slot ->
      let field_ofs = Uint32.to_int (PS.Field.Slot.offset_get slot) in
      let tp = PS.Field.Slot.type_get slot in
      let default = PS.Field.Slot.defaultValue_get slot in
      begin match (PS.Type.unnamed_union_get tp,
        PS.Value.unnamed_union_get default) with
      | (PS.Type.Void, PS.Value.Void) ->
          sprintf "%slet %s_get x = ()\n" indent field_name
      | (PS.Type.Bool, PS.Value.Bool a) ->
          (sprintf "%slet %s_get x = \
                    get_struct_field_bit ~default_bit:%s x %u %u\n"
            indent
            field_name
            (if a then "true" else "false")
            (field_ofs / 8)
            (field_ofs mod 8)) ^
          (sprintf
            "%slet %s_set x v = set_struct_field_bit %s~default_bit:%s x %u %u v\n"
            indent
            field_name
            discr_str
            (if a then "true" else "false")
            (field_ofs / 8)
            (field_ofs mod 8))
      | (PS.Type.Int8, PS.Value.Int8 a) ->
          (sprintf "%slet %s_get x = get_struct_field_int8 ~default:%d x %u\n"
            indent
            field_name
            a
            field_ofs) ^
          (sprintf
            "%slet %s_set x v = set_struct_field_int8 %s~default:%d x %u v\n"
            indent
            field_name
            discr_str
            a
            field_ofs)
      | (PS.Type.Int16, PS.Value.Int16 a) ->
          (sprintf "%slet %s_get x = get_struct_field_int16 ~default:%d x %u\n"
            indent
            field_name
            a
            (field_ofs * 2)) ^
          (sprintf
            "%slet %s_set x v = set_struct_field_int16 %s~default:%d x %u v\n"
            indent
            field_name
            discr_str
            a
            (field_ofs * 2))
      | (PS.Type.Int32, PS.Value.Int32 a) ->
          (sprintf "%slet %s_get x = get_struct_field_int32 ~default:%sl x %u\n"
            indent
            field_name
            (Int32.to_string a)
            (field_ofs * 4)) ^
          (sprintf "%slet %s_get_int_exn x = Int32.to_int (%s_get x)\n"
            indent
            field_name
            field_name) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_int32 %s~default:%sl x %u v\n"
            indent
            field_name
            discr_str
            (Int32.to_string a)
            (field_ofs * 4)) ^
          (sprintf "%slet %s_set_int_exn x = %s_set x (Int32.of_int v)\n"
            indent
            field_name
            field_name)
      | (PS.Type.Int64, PS.Value.Int64 a) ->
          (sprintf "%slet %s_get x = get_struct_field_int64 ~default:%sL x %u\n"
            indent
            field_name
            (Int64.to_string a)
            (field_ofs * 8)) ^
          (sprintf "%slet %s_get_int_exn x = Int64.to_int (%s_get x)\n"
            indent
            field_name
            field_name) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_int64 %s~default:%sL x %u v\n"
            indent
            field_name
            discr_str
            (Int64.to_string a)
            (field_ofs * 8)) ^
          (sprintf "%slet %s_set_int_exn x v = %s_set x (Int64.of_int v)\n"
            indent
            field_name
            field_name)
      | (PS.Type.Uint8, PS.Value.Uint8 a) ->
          (sprintf "%slet %s_get x = get_struct_field_uint8 ~default:%d x %u\n"
            indent
            field_name
            a
            field_ofs) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_uint8 %s~default:%d x %u v\n"
            indent
            field_name
            discr_str
            a
            field_ofs)
      | (PS.Type.Uint16, PS.Value.Uint16 a) ->
          (sprintf "%slet %s_get x = get_struct_field_uint16 ~default:%d x %u\n"
            indent
            field_name
            a
            (field_ofs * 2)) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_uint16 %s~default:%d x %u v\n"
            indent
            field_name
            discr_str
            a
            (field_ofs * 2))
      | (PS.Type.Uint32, PS.Value.Uint32 a) ->
          let default =
            if Uint32.compare a Uint32.zero = 0 then
              "Uint32.zero"
            else
              sprintf "(Uint32.of_string \"%s\")" (Uint32.to_string a)
          in
          (sprintf "%slet %s_get x = get_struct_field_uint32 ~default:%s x %u\n"
            indent
            field_name
            default
            (field_ofs * 4)) ^
          (sprintf "%slet %s_get_int_exn x = Uint32.to_int (%s_get x)\n"
            indent
            field_name
            field_name) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_uint32 %s~default:%s x %u v\n"
            indent
            field_name
            discr_str
            default
            (field_ofs * 4)) ^
          (sprintf "%slet %s_set_int_exn x v = %s_set x (Uint32.of_int v)\n"
            indent
            field_name
            field_name)
      | (PS.Type.Uint64, PS.Value.Uint64 a) ->
          let default =
            if Uint64.compare a Uint64.zero = 0 then
              "Uint64.zero"
            else
              sprintf "(Uint64.of_string \"%s\")" (Uint64.to_string a)
          in
          (sprintf "%slet %s_get x = get_struct_field_uint64 ~default:%s x %u\n"
            indent
            field_name
            default
            (field_ofs * 8)) ^
          (sprintf "%slet %s_get_int_exn x = Uint64.to_int (%s_get x)\n"
            indent
            field_name
            field_name) ^
          (sprintf "%slet %s_set x v = \
                    set_struct_field_uint64 %s~default:%s x %u v\n"
            indent
            field_name
            discr_str
            default
            (field_ofs * 8)) ^
          (sprintf "%slet %s_set_int_exn x v = %s_set x (Uint64.of_int v)\n"
            indent
            field_name
            field_name)
      | (PS.Type.Float32, PS.Value.Float32 a) ->
          let default_int32 = Int32.bits_of_float a in
          (sprintf
             "%slet %s_get x = Int32.float_of_bits \
              (get_struct_field_int32 ~default:%sl x %u)\n"
            indent
            field_name
            (Int32.to_string default_int32)
            (field_ofs * 4)) ^
          (sprintf
             "%slet %s_set x v = set_struct_field_int32 %s~default:%sl x %u \
              (Int32.bits_of_float v)\n"
            indent
            field_name
            discr_str
            (Int32.to_string default_int32)
            (field_ofs * 4))
      | (PS.Type.Float64, PS.Value.Float64 a) ->
          let default_int64 = Int64.bits_of_float a in
          (sprintf
             "%slet %s_get x = Int64.float_of_bits \
              (get_struct_field_int64 ~default:%sL x %u)\n"
            indent
            field_name
            (Int64.to_string default_int64)
            (field_ofs * 8)) ^
          (sprintf
             "%slet %s_set x = set_struct_field_int64 %s~default:%sL x %u \
              (Int64.bits_of_float v)\n"
            indent
            field_name
            discr_str
            (Int64.to_string default_int64)
            (field_ofs * 8))
      | (PS.Type.Text, PS.Value.Text a) ->
          (sprintf
             "%slet %s_get x = \
              get_struct_field_text ~default:\"%s\" x %u\n"
            indent
            field_name
            (String.escaped a)
            (field_ofs * 8)) ^
          (sprintf
             "%slet %s_set x v = \
              set_struct_field_text %sx %u v\n"
            indent
            field_name
            discr_str
            (field_ofs * 8))
      | (PS.Type.Data, PS.Value.Data a) ->
          (sprintf
             "%slet %s_get x = \
              get_struct_field_blob ~default:\"%s\" x %u\n"
            indent
            field_name
            (String.escaped a)
            (field_ofs * 8)) ^
          (sprintf
             "%slet %s_set x v = \
              set_struct_field_blob %sx %u v\n"
            indent
            field_name
            discr_str
            (field_ofs * 8))
      | (PS.Type.List list_def, PS.Value.List pointer_slice_opt) ->
          let has_trivial_default =
            begin match pointer_slice_opt with
            | Some pointer_slice ->
                begin match Builder.decode_pointer pointer_slice with
                | Pointer.Null -> true
                | _ -> false
                end
            | None ->
                true
            end
          in
          if has_trivial_default then
            let list_type = PS.Type.List.elementType_get list_def in
            generate_list_accessor ~nodes_table ~scope ~list_type ~indent
              ~field_name ~field_ofs ~discr_str
          else
            failwith "Default values for lists are not implemented."
      | (PS.Type.Enum enum_def, PS.Value.Enum val_uint16) ->
          let enum_id = PS.Type.Enum.typeId_get enum_def in
          let enum_node = Hashtbl.find_exn nodes_table enum_id in
          (generate_enum_getter
            ~nodes_table ~scope ~enum_node ~indent ~field_name ~field_ofs
            ~default:val_uint16) ^
          (generate_enum_safe_setter
            ~nodes_table ~scope ~enum_node ~indent ~field_name ~field_ofs
            ~default:val_uint16 ~discr_str) ^
          (generate_enum_unsafe_setter
            ~nodes_table ~scope ~enum_node ~indent ~field_name ~field_ofs
            ~default:val_uint16 ~discr_str)
      | (PS.Type.Struct struct_def, PS.Value.Struct pointer_slice_opt) ->
          let has_trivial_default =
            begin match pointer_slice_opt with
            | Some pointer_slice ->
                begin match Builder.decode_pointer pointer_slice with
                | Pointer.Null -> true
                | _ -> false
                end
            | None ->
                true
            end
          in
          if has_trivial_default then
            let id = PS.Type.Struct.typeId_get struct_def in
            let node = Hashtbl.find_exn nodes_table id in
            match PS.Node.unnamed_union_get node with
            | PS.Node.Struct struct_def' ->
                let data_words =
                  PS.Node.Struct.dataWordCount_get struct_def'
                in
                let pointer_words =
                  PS.Node.Struct.pointerCount_get struct_def'
                in
                (sprintf
                  "%slet %s_get x = get_struct_field_struct x %u \
                   ~data_words:%u ~pointer_words:%u\n"
                  indent
                  field_name
                  field_ofs
                  data_words
                  pointer_words) ^
                (sprintf
                   "%slet %s_set x v = set_struct_field_struct x %u v \
                    %s~data_words:%u ~pointer_words:%u\n"
                   indent
                   field_name
                   field_ofs
                   discr_str
                   data_words
                   pointer_words)
            | _ ->
                failwith
                  "decoded non-struct node where struct node was expected."
          else
            failwith "Default values for structs are not implemented."
      | (PS.Type.Interface iface_def, PS.Value.Interface) ->
          sprintf "%slet %s_get x = failwith \"not implemented\"\n"
            indent
            field_name
      | (PS.Type.AnyPointer, PS.Value.AnyPointer pointer) ->
          sprintf "%slet %s_get x = get_struct_pointer x %u\n"
            indent
            field_name
            field_ofs
      | (PS.Type.Undefined_ x, _) ->
          failwith (sprintf "Unknown Field union discriminant %u." x)

      (* All other cases represent an ill-formed default value in the plugin request *)
      | (PS.Type.Void, _)
      | (PS.Type.Bool, _)
      | (PS.Type.Int8, _)
      | (PS.Type.Int16, _)
      | (PS.Type.Int32, _)
      | (PS.Type.Int64, _)
      | (PS.Type.Uint8, _)
      | (PS.Type.Uint16, _)
      | (PS.Type.Uint32, _)
      | (PS.Type.Uint64, _)
      | (PS.Type.Float32, _)
      | (PS.Type.Float64, _)
      | (PS.Type.Text, _)
      | (PS.Type.Data, _)
      | (PS.Type.List _, _)
      | (PS.Type.Enum _, _)
      | (PS.Type.Struct _, _)
      | (PS.Type.Interface _, _)
      | (PS.Type.AnyPointer, _) ->
          let err_msg = sprintf
              "The default value for field \"%s\" has an unexpected type."
              field_name
          in
          failwith err_msg
      end
  | PS.Field.Undefined_ x ->
      failwith (sprintf "Unknown Field union discriminant %u." x)


(* Generate accessors for retrieving all fields of a struct, regardless of whether
 * or not the fields are packed into a union.  (Fields packed inside a union are
 * not exposed in the module signature. *)
let generate_accessors ~nodes_table ~scope struct_def fields =
  let indent = String.make (2 * (List.length scope + 2)) ' ' in
  let discr_ofs = Uint32.to_int (PS.Node.Struct.discriminantOffset_get struct_def) in
  let accessors = List.fold_left fields ~init:[] ~f:(fun acc field ->
    let x = generate_field_accessors ~nodes_table ~scope ~indent ~discr_ofs field in
    x :: acc)
  in
  String.concat ~sep:"" accessors


(* Generate the OCaml module corresponding to a struct definition.  [scope] is a
 * stack of scope IDs corresponding to this lexical context, and is used to figure
 * out what module prefixes are required to properly qualify a type.
 *
 * Raises: Failure if the children of this node contain a cycle. *)
let rec generate_struct_node ~nodes_table ~scope ~nested_modules ~node struct_def =
  let unsorted_fields =
    let fields_accessor = PS.Node.Struct.fields_get struct_def in
    let rec loop_fields acc i =
      if i = R.Array.length fields_accessor then
        acc
      else
        let field = R.Array.get fields_accessor i in
        loop_fields (field :: acc) (i + 1)
    in
    loop_fields [] 0
  in
  (* Sorting in reverse code order allows us to avoid a List.rev *)
  let all_fields = List.sort unsorted_fields ~cmp:(fun x y ->
    - (Int.compare (PS.Field.codeOrder_get x) (PS.Field.codeOrder_get y)))
  in
  let union_fields = List.filter all_fields ~f:(fun field ->
    (PS.Field.discriminantValue_get field) <> PS.Field.noDiscriminant)
  in
  let accessors =
    generate_accessors ~nodes_table ~scope struct_def all_fields
  in
  let union_accessors =
    match union_fields with
    | [] ->
        ""
    | _  ->
        (GenReader.generate_union_accessor ~nodes_table ~scope
           struct_def union_fields)
  in
  let indent = String.make (2 * (List.length scope + 2)) ' ' in
  (sprintf "%stype t = Reader.%s.builder_t = rw StructStorage.t\n"
     indent
     (GenCommon.get_fully_qualified_name nodes_table node)) ^
  (sprintf "%stype %s = t\n" indent
     (GenCommon.make_unique_typename ~mode:Mode.Builder
        ~scope_mode:Mode.Builder ~nodes_table node)) ^
  (sprintf "%stype reader_t = Reader.%s.t\n" indent
     (GenCommon.get_fully_qualified_name nodes_table node)) ^
  (sprintf "%stype %s = reader_t\n" indent
     (GenCommon.make_unique_typename ~mode:Mode.Reader
        ~scope_mode:Mode.Builder ~nodes_table node)) ^
  (sprintf "%stype array_t = rw ListStorage.t\n\n" indent) ^
    nested_modules ^ accessors ^ union_accessors ^
    (sprintf "%slet of_message x = get_root_struct x\n" indent)


(* Generate the OCaml module and type signature corresponding to a node.  [scope] is
 * a stack of scope IDs corresponding to this lexical context, and is used to figure out
 * what module prefixes are required to properly qualify a type.
 *
 * Raises: Failure if the children of this node contain a cycle. *)
and generate_node
    ~(suppress_module_wrapper : bool)
    ~(nodes_table : (Uint64.t, PS.Node.t) Hashtbl.t)
    ~(scope : Uint64.t list)
    ~(node_name : string)
    (node : PS.Node.t)
: string =
  let node_id = PS.Node.id_get node in
  let indent = String.make (2 * (List.length scope + 1)) ' ' in
  let generate_nested_modules () =
    match Topsort.topological_sort nodes_table
            (GenCommon.children_of nodes_table node) with
    | Some child_nodes ->
        let child_modules = List.map child_nodes ~f:(fun child ->
          let child_name = GenCommon.get_unqualified_name ~parent:node ~child in
          generate_node ~suppress_module_wrapper:false ~nodes_table
            ~scope:(node_id :: scope) ~node_name:child_name child)
        in
        begin match child_modules with
        | [] -> ""
        | _  -> (String.concat ~sep:"\n" child_modules) ^ "\n"
        end
    | None ->
        let error_msg = sprintf
          "The children of node %s (%s) have a cyclic dependency."
          (Uint64.to_string node_id)
          (PS.Node.displayName_get node)
        in
        failwith error_msg
  in
  match PS.Node.unnamed_union_get node with
  | PS.Node.File ->
      generate_nested_modules ()
  | PS.Node.Struct struct_def ->
      let nested_modules = generate_nested_modules () in
      let body =
        generate_struct_node ~nodes_table ~scope ~nested_modules ~node struct_def
      in
      if suppress_module_wrapper then
        body
      else
        (sprintf "%smodule %s = struct\n" indent node_name) ^
        body ^
        (sprintf "%send\n" indent)
  | PS.Node.Enum enum_def ->
      let nested_modules = generate_nested_modules () in
      let body =
        GenCommon.generate_enum_sig ~nodes_table ~scope ~nested_modules
          ~mode:GenCommon.Mode.Builder ~node enum_def
      in
      if suppress_module_wrapper then
        body
      else
        (sprintf "%smodule %s = struct\n" indent node_name) ^
        body ^
        (sprintf "%send\n" indent)
  | PS.Node.Interface iface_def ->
      generate_nested_modules ()
  | PS.Node.Const const_def ->
      sprintf "%slet %s = %s\n"
        indent
        (String.uncapitalize node_name)
        (GenCommon.generate_constant ~nodes_table ~scope const_def)
  | PS.Node.Annotation annot_def ->
      generate_nested_modules ()
  | PS.Node.Undefined_ x ->
      failwith (sprintf "Unknown Node union discriminant %u" x)

