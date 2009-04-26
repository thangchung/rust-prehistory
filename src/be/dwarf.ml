(*
 * Walk crate and generate DWARF-3 records. This file might also go in
 * the me/ directory; it's half-middle-end, half-back-end. Debug info is
 * like that.
 *
 * Some notes about DWARF:
 *
 *   - Records form an ownership tree. The tree is serialized in
 *     depth-first pre-order with child lists ending with null
 *     records. When a node type is defined to have no children, no null
 *     child record is provided; it's implied.
 *
 *               [parent]
 *                /    \
 *          [child1]  [child2]
 *              |
 *          [grandchild1]
 *
 *     serializes as:
 *
 *          [parent][child1][grandchild1][null][child2][null][null]
 *
 *   - Sometimes you want to make it possible to scan through a sibling
 *     list quickly while skipping the sub-children of each (such as
 *     skipping the 'grandchild' above); this can be done with a
 *     DW_AT_sibling attribute that points forward to the next same-level
 *     sibling.
 *
 *   - A DWARF consumer contains a little stack-machine interpreter for
 *     a micro-language that you can embed in DWARF records to compute
 *     values algorithmically.
 *
 *   - DWARF is not "officially" supported by any Microsoft tools in
 *     PE files, but the Microsoft debugging information formats are
 *     proprietary and ever-shifting, and not clearly sufficient for
 *     our needs; by comparison DWARF is widely supported, stable,
 *     flexible, and required everywhere *else*. We are using DWARF to
 *     support major components of the rust runtime (reflection,
 *     unwinding, profiling) so it's helpful to not have to span
 *     technologies, just focus on DWARF.  Luckily the MINGW/Cygwin
 *     communities have worked out a convention for PE, and taught BFD
 *     (thus most tools) how to digest DWARF sections trailing after
 *     the .idata section of a normal PE file. Seems to work fine.
 * 
 *   - DWARF supports variable-length coding using LEB128, and in the
 *     cases where these are symbolic or self-contained numbers, we
 *     support them in the assembler. Inter-DWARF-record references
 *     can be done via fixed-size DW_FORM_ref{1,2,4,8} or
 *     DW_FORM_ref_addr; or else via variable-size (LEB128)
 *     DW_FORM_ref_udata. It is hazardous to use the LEB128 form in
 *     our implementation of references, since we use a generic 2-pass
 *     (+ relaxation) fixup mechanism in our assembler which in
 *     general may present an information-dependency cycle for LEB128
 *     coding of offsets: you need to know the offset before you can
 *     work out the LEB128 size, and you may need to know several
 *     LEB128-sizes before you can work out the offsets of other
 *     LEB128s (possibly even the one you're currently coding). In
 *     general the assembler makes no attempt to resolve such
 *     cycles. It'll just throw if it can't handle what you ask
 *     for. So it's best to pay a little extra space and use
 *     DW_FORM_ref_addr or DW_FORM_ref{1,2,4,8} values, in all cases.
 *)

open Semant;;
open Common;;
open Asm;;

let log cx = Session.log "dwarf"
  cx.ctxt_sess.Session.sess_log_dwarf
  cx.ctxt_sess.Session.sess_log_out
;;

type dw_tag =
    DW_TAG_array_type
  | DW_TAG_class_type
  | DW_TAG_entry_point
  | DW_TAG_enumeration_type
  | DW_TAG_formal_parameter
  | DW_TAG_imported_declaration
  | DW_TAG_label
  | DW_TAG_lexical_block
  | DW_TAG_member
  | DW_TAG_pointer_type
  | DW_TAG_reference_type
  | DW_TAG_compile_unit
  | DW_TAG_string_type
  | DW_TAG_structure_type
  | DW_TAG_subroutine_type
  | DW_TAG_typedef
  | DW_TAG_union_type
  | DW_TAG_unspecified_parameters
  | DW_TAG_variant
  | DW_TAG_common_block
  | DW_TAG_common_inclusion
  | DW_TAG_inheritance
  | DW_TAG_inlined_subroutine
  | DW_TAG_module
  | DW_TAG_ptr_to_member_type
  | DW_TAG_set_type
  | DW_TAG_subrange_type
  | DW_TAG_with_stmt
  | DW_TAG_access_declaration
  | DW_TAG_base_type
  | DW_TAG_catch_block
  | DW_TAG_const_type
  | DW_TAG_constant
  | DW_TAG_enumerator
  | DW_TAG_file_type
  | DW_TAG_friend
  | DW_TAG_namelist
  | DW_TAG_namelist_item
  | DW_TAG_packed_type
  | DW_TAG_subprogram
  | DW_TAG_template_type_parameter
  | DW_TAG_template_value_parameter
  | DW_TAG_thrown_type
  | DW_TAG_try_block
  | DW_TAG_variant_part
  | DW_TAG_variable
  | DW_TAG_volatile_type
  | DW_TAG_dwarf_procedure
  | DW_TAG_restrict_type
  | DW_TAG_interface_type
  | DW_TAG_namespace
  | DW_TAG_imported_module
  | DW_TAG_unspecified_type
  | DW_TAG_partial_unit
  | DW_TAG_imported_unit
  | DW_TAG_condition
  | DW_TAG_shared_type
  | DW_TAG_lo_user
  | DW_TAG_hi_user
;;


let dw_tag_to_int (tag:dw_tag) : int =
  match tag with
    DW_TAG_array_type -> 0x01
  | DW_TAG_class_type -> 0x02
  | DW_TAG_entry_point -> 0x03
  | DW_TAG_enumeration_type -> 0x04
  | DW_TAG_formal_parameter -> 0x05
  | DW_TAG_imported_declaration -> 0x08
  | DW_TAG_label -> 0x0a
  | DW_TAG_lexical_block -> 0x0b
  | DW_TAG_member -> 0x0d
  | DW_TAG_pointer_type -> 0x0f
  | DW_TAG_reference_type -> 0x10
  | DW_TAG_compile_unit -> 0x11
  | DW_TAG_string_type -> 0x12
  | DW_TAG_structure_type -> 0x13
  | DW_TAG_subroutine_type -> 0x15
  | DW_TAG_typedef -> 0x16
  | DW_TAG_union_type -> 0x17
  | DW_TAG_unspecified_parameters -> 0x18
  | DW_TAG_variant -> 0x19
  | DW_TAG_common_block -> 0x1a
  | DW_TAG_common_inclusion -> 0x1b
  | DW_TAG_inheritance -> 0x1c
  | DW_TAG_inlined_subroutine -> 0x1d
  | DW_TAG_module -> 0x1e
  | DW_TAG_ptr_to_member_type -> 0x1f
  | DW_TAG_set_type -> 0x20
  | DW_TAG_subrange_type -> 0x21
  | DW_TAG_with_stmt -> 0x22
  | DW_TAG_access_declaration -> 0x23
  | DW_TAG_base_type -> 0x24
  | DW_TAG_catch_block -> 0x25
  | DW_TAG_const_type -> 0x26
  | DW_TAG_constant -> 0x27
  | DW_TAG_enumerator -> 0x28
  | DW_TAG_file_type -> 0x29
  | DW_TAG_friend -> 0x2a
  | DW_TAG_namelist -> 0x2b
  | DW_TAG_namelist_item -> 0x2c
  | DW_TAG_packed_type -> 0x2d
  | DW_TAG_subprogram -> 0x2e
  | DW_TAG_template_type_parameter -> 0x2f
  | DW_TAG_template_value_parameter -> 0x30
  | DW_TAG_thrown_type -> 0x31
  | DW_TAG_try_block -> 0x32
  | DW_TAG_variant_part -> 0x33
  | DW_TAG_variable -> 0x34
  | DW_TAG_volatile_type -> 0x35
  | DW_TAG_dwarf_procedure -> 0x36
  | DW_TAG_restrict_type -> 0x37
  | DW_TAG_interface_type -> 0x38
  | DW_TAG_namespace -> 0x39
  | DW_TAG_imported_module -> 0x3a
  | DW_TAG_unspecified_type -> 0x3b
  | DW_TAG_partial_unit -> 0x3c
  | DW_TAG_imported_unit -> 0x3d
  | DW_TAG_condition -> 0x3f
  | DW_TAG_shared_type -> 0x40
  | DW_TAG_lo_user -> 0x4080
  | DW_TAG_hi_user -> 0xffff
;;


type dw_children =
    DW_CHILDREN_no
  | DW_CHILDREN_yes
;;


let dw_children_to_int (ch:dw_children) : int =
  match ch with
      DW_CHILDREN_no -> 0x00
    | DW_CHILDREN_yes -> 0x01
;;

type dw_at =
    DW_AT_sibling
  | DW_AT_location
  | DW_AT_name
  | DW_AT_ordering
  | DW_AT_byte_size
  | DW_AT_bit_offset
  | DW_AT_bit_size
  | DW_AT_stmt_list
  | DW_AT_low_pc
  | DW_AT_high_pc
  | DW_AT_language
  | DW_AT_discr
  | DW_AT_discr_value
  | DW_AT_visibility
  | DW_AT_import
  | DW_AT_string_length
  | DW_AT_common_reference
  | DW_AT_comp_dir
  | DW_AT_const_value
  | DW_AT_containing_type
  | DW_AT_default_value
  | DW_AT_inline
  | DW_AT_is_optional
  | DW_AT_lower_bound
  | DW_AT_producer
  | DW_AT_prototyped
  | DW_AT_return_addr
  | DW_AT_start_scope
  | DW_AT_bit_stride
  | DW_AT_upper_bound
  | DW_AT_abstract_origin
  | DW_AT_accessibility
  | DW_AT_address_class
  | DW_AT_artificial
  | DW_AT_base_types
  | DW_AT_calling_convention
  | DW_AT_count
  | DW_AT_data_member_location
  | DW_AT_decl_column
  | DW_AT_decl_file
  | DW_AT_decl_line
  | DW_AT_declaration
  | DW_AT_discr_list
  | DW_AT_encoding
  | DW_AT_external
  | DW_AT_frame_base
  | DW_AT_friend
  | DW_AT_identifier_case
  | DW_AT_macro_info
  | DW_AT_namelist_item
  | DW_AT_priority
  | DW_AT_segment
  | DW_AT_specification
  | DW_AT_static_link
  | DW_AT_type
  | DW_AT_use_location
  | DW_AT_variable_parameter
  | DW_AT_virtuality
  | DW_AT_vtable_elem_location
  | DW_AT_allocated
  | DW_AT_associated
  | DW_AT_data_location
  | DW_AT_byte_stride
  | DW_AT_entry_pc
  | DW_AT_use_UTF8
  | DW_AT_extension
  | DW_AT_ranges
  | DW_AT_trampoline
  | DW_AT_call_column
  | DW_AT_call_file
  | DW_AT_call_line
  | DW_AT_description
  | DW_AT_binary_scale
  | DW_AT_decimal_scale
  | DW_AT_small
  | DW_AT_decimal_sign
  | DW_AT_digit_count
  | DW_AT_picture_string
  | DW_AT_mutable
  | DW_AT_threads_scaled
  | DW_AT_explicit
  | DW_AT_object_pointer
  | DW_AT_endianity
  | DW_AT_elemental
  | DW_AT_pure
  | DW_AT_recursive
  | DW_AT_lo_user
  | DW_AT_hi_user
;;


let dw_at_to_int (a:dw_at) : int =
  match a with
      DW_AT_sibling -> 0x01
    | DW_AT_location -> 0x02
    | DW_AT_name -> 0x03
    | DW_AT_ordering -> 0x09
    | DW_AT_byte_size -> 0x0b
    | DW_AT_bit_offset -> 0x0c
    | DW_AT_bit_size -> 0x0d
    | DW_AT_stmt_list -> 0x10
    | DW_AT_low_pc -> 0x11
    | DW_AT_high_pc -> 0x12
    | DW_AT_language -> 0x13
    | DW_AT_discr -> 0x15
    | DW_AT_discr_value -> 0x16
    | DW_AT_visibility -> 0x17
    | DW_AT_import -> 0x18
    | DW_AT_string_length -> 0x19
    | DW_AT_common_reference -> 0x1a
    | DW_AT_comp_dir -> 0x1b
    | DW_AT_const_value -> 0x1c
    | DW_AT_containing_type -> 0x1d
    | DW_AT_default_value -> 0x1e
    | DW_AT_inline -> 0x20
    | DW_AT_is_optional -> 0x21
    | DW_AT_lower_bound -> 0x22
    | DW_AT_producer -> 0x25
    | DW_AT_prototyped -> 0x27
    | DW_AT_return_addr -> 0x2a
    | DW_AT_start_scope -> 0x2c
    | DW_AT_bit_stride -> 0x2e
    | DW_AT_upper_bound -> 0x2f
    | DW_AT_abstract_origin -> 0x31
    | DW_AT_accessibility -> 0x32
    | DW_AT_address_class -> 0x33
    | DW_AT_artificial -> 0x34
    | DW_AT_base_types -> 0x35
    | DW_AT_calling_convention -> 0x36
    | DW_AT_count -> 0x37
    | DW_AT_data_member_location -> 0x38
    | DW_AT_decl_column -> 0x39
    | DW_AT_decl_file -> 0x3a
    | DW_AT_decl_line -> 0x3b
    | DW_AT_declaration -> 0x3c
    | DW_AT_discr_list -> 0x3d
    | DW_AT_encoding -> 0x3e
    | DW_AT_external -> 0x3f
    | DW_AT_frame_base -> 0x40
    | DW_AT_friend -> 0x41
    | DW_AT_identifier_case -> 0x42
    | DW_AT_macro_info -> 0x43
    | DW_AT_namelist_item -> 0x44
    | DW_AT_priority -> 0x45
    | DW_AT_segment -> 0x46
    | DW_AT_specification -> 0x47
    | DW_AT_static_link -> 0x48
    | DW_AT_type -> 0x49
    | DW_AT_use_location -> 0x4a
    | DW_AT_variable_parameter -> 0x4b
    | DW_AT_virtuality -> 0x4c
    | DW_AT_vtable_elem_location -> 0x4d
    | DW_AT_allocated -> 0x4e
    | DW_AT_associated -> 0x4f
    | DW_AT_data_location -> 0x50
    | DW_AT_byte_stride -> 0x51
    | DW_AT_entry_pc -> 0x52
    | DW_AT_use_UTF8 -> 0x53
    | DW_AT_extension -> 0x54
    | DW_AT_ranges -> 0x55
    | DW_AT_trampoline -> 0x56
    | DW_AT_call_column -> 0x57
    | DW_AT_call_file -> 0x58
    | DW_AT_call_line -> 0x59
    | DW_AT_description -> 0x5a
    | DW_AT_binary_scale -> 0x5b
    | DW_AT_decimal_scale -> 0x5c
    | DW_AT_small -> 0x5d
    | DW_AT_decimal_sign -> 0x5e
    | DW_AT_digit_count -> 0x5f
    | DW_AT_picture_string -> 0x60
    | DW_AT_mutable -> 0x61
    | DW_AT_threads_scaled -> 0x62
    | DW_AT_explicit -> 0x63
    | DW_AT_object_pointer -> 0x64
    | DW_AT_endianity -> 0x65
    | DW_AT_elemental -> 0x66
    | DW_AT_pure -> 0x67
    | DW_AT_recursive -> 0x68
    | DW_AT_lo_user -> 0x2000
    | DW_AT_hi_user -> 0x3fff
;;


type dw_form =
  | DW_FORM_addr
  | DW_FORM_block2
  | DW_FORM_block4
  | DW_FORM_data2
  | DW_FORM_data4
  | DW_FORM_data8
  | DW_FORM_string
  | DW_FORM_block
  | DW_FORM_block1
  | DW_FORM_data1
  | DW_FORM_flag
  | DW_FORM_sdata
  | DW_FORM_strp
  | DW_FORM_udata
  | DW_FORM_ref_addr
  | DW_FORM_ref1
  | DW_FORM_ref2
  | DW_FORM_ref4
  | DW_FORM_ref8
  | DW_FORM_ref_udata
  | DW_FORM_indirect
;;

let dw_form_to_int (f:dw_form) : int =
  match f with
    | DW_FORM_addr -> 0x01
    | DW_FORM_block2 -> 0x03
    | DW_FORM_block4 -> 0x04
    | DW_FORM_data2 -> 0x05
    | DW_FORM_data4 -> 0x06
    | DW_FORM_data8 -> 0x07
    | DW_FORM_string -> 0x08
    | DW_FORM_block -> 0x09
    | DW_FORM_block1 -> 0x0a
    | DW_FORM_data1 -> 0x0b
    | DW_FORM_flag -> 0x0c
    | DW_FORM_sdata -> 0x0d
    | DW_FORM_strp -> 0x0e
    | DW_FORM_udata -> 0x0f
    | DW_FORM_ref_addr -> 0x10
    | DW_FORM_ref1 -> 0x11
    | DW_FORM_ref2 -> 0x12
    | DW_FORM_ref4 -> 0x13
    | DW_FORM_ref8 -> 0x14
    | DW_FORM_ref_udata -> 0x15
    | DW_FORM_indirect -> 0x16
;;

type dw_lns =
      DW_LNS_copy
    | DW_LNS_advance_pc
    | DW_LNS_advance_line
    | DW_LNS_set_file
    | DW_LNS_set_column
    | DW_LNS_negage_stmt
    | DW_LNS_set_basic_block
    | DW_LNS_const_add_pc
    | DW_LNS_fixed_advance_pc
    | DW_LNS_set_prologue_end
    | DW_LNS_set_epilogue_begin
    | DW_LNS_set_isa
;;

let int_to_dw_lns i =
  match i with
      1 -> DW_LNS_copy
    | 2 -> DW_LNS_advance_pc
    | 3 -> DW_LNS_advance_line
    | 4 -> DW_LNS_set_file
    | 5 -> DW_LNS_set_column
    | 6 -> DW_LNS_negage_stmt
    | 7 -> DW_LNS_set_basic_block
    | 8 -> DW_LNS_const_add_pc
    | 9 -> DW_LNS_fixed_advance_pc
    | 10 -> DW_LNS_set_prologue_end
    | 11 -> DW_LNS_set_epilogue_begin
    | 12 -> DW_LNS_set_isa
    | _ -> failwith ("Internal logic error: (Dwarf.int_to_dw_lns " ^ (string_of_int i) ^ ")")
;;

let dw_lns_to_int lns =
  match lns with
      DW_LNS_copy -> 1
    | DW_LNS_advance_pc -> 2
    | DW_LNS_advance_line -> 3
    | DW_LNS_set_file -> 4
    | DW_LNS_set_column -> 5
    | DW_LNS_negage_stmt -> 6
    | DW_LNS_set_basic_block -> 7
    | DW_LNS_const_add_pc -> 8
    | DW_LNS_fixed_advance_pc -> 9
    | DW_LNS_set_prologue_end -> 10
    | DW_LNS_set_epilogue_begin -> 11
    | DW_LNS_set_isa -> 12
;;

let max_dw_lns = 12;;

let dw_lns_arity lns =
  match lns with
      DW_LNS_copy -> 0
    | DW_LNS_advance_pc -> 1
    | DW_LNS_advance_line -> 1
    | DW_LNS_set_file -> 1
    | DW_LNS_set_column -> 1
    | DW_LNS_negage_stmt -> 0
    | DW_LNS_set_basic_block -> 0
    | DW_LNS_const_add_pc -> 0
    | DW_LNS_fixed_advance_pc -> 1
    | DW_LNS_set_prologue_end -> 0
    | DW_LNS_set_epilogue_begin -> 0
    | DW_LNS_set_isa -> 1
;;

type debug_records =
    {
      debug_aranges: Asm.item;
      debug_pubnames: Asm.item;
      debug_info: Asm.item;
      debug_abbrev: Asm.item;
      debug_line: Asm.item;
      debug_frame: Asm.item;

      debug_aranges_fixup: fixup;
      debug_pubnames_fixup: fixup;
      debug_info_fixup: fixup;
      debug_abbrev_fixup: fixup;
      debug_line_fixup: fixup;
      debug_frame_fixup: fixup;
    }

type abbrev = (dw_tag * dw_children * ((dw_at * dw_form) array));;

let (abbrev_cu:abbrev) =
  (DW_TAG_compile_unit, DW_CHILDREN_yes,
   [|
     (DW_AT_name, DW_FORM_string);
     (DW_AT_low_pc, DW_FORM_addr);
     (DW_AT_high_pc, DW_FORM_addr)
   |])
;;

let (abbrev_subprogram:abbrev) =
  (DW_TAG_subprogram, DW_CHILDREN_yes,
   [|
     (DW_AT_name, DW_FORM_string);
     (DW_AT_low_pc, DW_FORM_addr);
     (DW_AT_high_pc, DW_FORM_addr)
   |])
;;

let prepend lref x = lref := x :: (!lref)
;;


let dwarf_visitor
    (cx:ctxt)
    (inner:Walk.visitor)
    (cu_aranges:(item list) ref)
    (cu_pubnames:(item list) ref)
    (cu_infos:(item list) ref)
    (cu_abbrevs:(item list) ref)
    (cu_lines:(item list) ref)
    (cu_frames:(item list) ref)
    : Walk.visitor =
  let (abbrev_table:(abbrev, int) Hashtbl.t) = Hashtbl.create 0 in

  let uleb i = ULEB128 (IMM (Int64.of_int i)) in

  let get_abbrev_code
      (ab:abbrev)
      : int =
    if Hashtbl.mem abbrev_table ab
    then Hashtbl.find abbrev_table ab
    else
      let n = (Hashtbl.length abbrev_table) + 1 in
      let (tag, children, attrs) = ab in
      let attr_ulebs = Array.create ((Array.length attrs) * 2) MARK in
        for i = 0 to (Array.length attrs) - 1 do
          let (attr, form) = attrs.(i) in
            attr_ulebs.(2*i) <- uleb (dw_at_to_int attr);
            attr_ulebs.((2*i)+1) <- uleb (dw_form_to_int form)
        done;
        let ab_item =
          (SEQ [|
             uleb n;
             uleb (dw_tag_to_int tag);
             BYTE (dw_children_to_int children);
             SEQ attr_ulebs;
             uleb 0; uleb 0;
           |])
        in
          prepend cu_abbrevs ab_item;
          htab_put abbrev_table ab n;
          n
  in

  let (curr_cu_aranges:(item list) ref) = ref [] in
  let (curr_cu_pubnames:(item list) ref) = ref [] in
  let (curr_cu_infos:(item list) ref) = ref [] in
  let (curr_cu_line:(item list) ref) = ref [] in
  let (curr_cu_frame:(item list) ref) = ref [] in

  let finish_cu_and_compose_headers _ =

    let pubnames_header_and_curr_pubnames =
      SEQ [| (BYTE 0) |]
    in

    let aranges_header_and_curr_aranges =
      SEQ [| (BYTE 0) |]
    in

    let cu_info_fixup = new_fixup "CU debug_info fixup" in
    let info_header_fixup = new_fixup "CU debug_info header" in
    let info_header_and_curr_infos =
      SEQ
        [|
          WORD (TY_u32, (ADD                                (* unit_length:            *)
                           ((F_SZ cu_info_fixup),           (* including this header,  *)
                            (F_SZ info_header_fixup))));    (* excluding this word.    *)
          DEF (info_header_fixup,
               (SEQ [|
                  WORD (TY_u16, IMM 2L);                    (* DWARF version           *)
                  (* Since we share abbrevs across all CUs, offset is always 0.        *)
                  WORD (TY_u32, IMM 0L);                    (* CU-abbrev offset.       *)
                  BYTE 4;                                   (* Size of an address.     *)
                |]));
          DEF (cu_info_fixup,
               SEQ (Array.of_list (List.rev (!curr_cu_infos))));
        |]
    in

    let cu_line_fixup = new_fixup "CU debug_line fixup" in
    let cu_line_header_fixup = new_fixup "CU debug_line header" in
    let line_header_fixup = new_fixup "CU debug_line header" in
    let line_header_and_curr_line =
      SEQ
        [|
          WORD (TY_u32, (ADD                                (* unit_length:             *)
                           ((F_SZ cu_line_fixup),           (* including this header,   *)
                            (F_SZ cu_line_header_fixup)))); (* excluding this word.     *)
          DEF (cu_line_header_fixup,
               (SEQ [|
                  WORD (TY_u16, IMM 2L);                    (* DWARF version.           *)
                  WORD (TY_u32, (F_SZ line_header_fixup));  (* Another header-length.   *)
                  DEF (line_header_fixup,
                       SEQ [|
                         BYTE 1;                            (* Minimum insn length.     *)
                         BYTE 1;                            (* default_is_stmt          *)
                         BYTE 0;                            (* line_base                *)
                         BYTE 0;                            (* line_range               *)
                         BYTE (max_dw_lns + 1);             (* opcode_base              *)
                         BYTES                              (* opcode arity array.      *)
                           (Array.init max_dw_lns
                              (fun i ->
                                 (dw_lns_arity
                                    (int_to_dw_lns
                                       (i+1)))));
                         (BYTE 0);                          (* List of include dirs.    *)
                         (BYTE 0);                          (* List of file entries.    *)
                       |])|]));
          DEF (cu_line_fixup,
               SEQ (Array.of_list (List.rev (!curr_cu_line))));
        |]
    in
    let frame_header_and_curr_frame =
      SEQ [| (BYTE 0) |]
    in
    let prepend_and_reset (curr_ref, accum_ref, header_and_curr) =
      prepend accum_ref header_and_curr;
      curr_ref := []
    in
      List.iter prepend_and_reset
        [ (curr_cu_aranges, cu_aranges, aranges_header_and_curr_aranges);
          (curr_cu_pubnames, cu_pubnames, pubnames_header_and_curr_pubnames);
          (curr_cu_infos, cu_infos, info_header_and_curr_infos);
          (curr_cu_line, cu_lines, line_header_and_curr_line);
          (curr_cu_frame, cu_frames, frame_header_and_curr_frame) ]
  in

  let begin_cu_and_emit_cu_die
      (name:string)
      (cu_text_fixup:fixup)
      : unit =
    let abbrev_code = get_abbrev_code abbrev_cu in
    let cu_info =
      (SEQ [|
         uleb abbrev_code;
         ZSTRING name;
         WORD (TY_u32, M_POS cu_text_fixup);
         WORD (TY_u32, ADD ((M_POS cu_text_fixup),
                            (M_SZ cu_text_fixup)))
       |])
    in
      curr_cu_infos := [cu_info];
      curr_cu_line := []
  in

  let emit_fn_die
      (name:string)
      (fix:fixup)
      : unit =
    let abbrev_code = get_abbrev_code abbrev_subprogram in
    let subprogram_die =
      (SEQ [|
         uleb abbrev_code;
         ZSTRING name;
         WORD (TY_u32, M_POS fix);
         WORD (TY_u32, (ADD ((M_POS fix), (M_SZ fix))))
       |])
    in
      prepend curr_cu_infos subprogram_die
  in

  let visit_mod_item_pre
      (id:Ast.ident)
      (params:(Ast.ty_limit * Ast.ident) array)
      (item:Ast.mod_item)
      : unit =
    if Hashtbl.mem cx.ctxt_item_files item.id
    then
      begin
        let filename = (Hashtbl.find cx.ctxt_item_files item.id) in
          log cx "walking CU '%s'" filename;
          begin_cu_and_emit_cu_die filename (Hashtbl.find cx.ctxt_file_fixups item.id);
      end
    else
      ();
    begin
      match item.node with
          Ast.MOD_ITEM_fn _ ->
            begin
              log cx "walking function '%s'" id;
              emit_fn_die id (Hashtbl.find cx.ctxt_fn_fixups item.id)
            end
        | _ -> ()
    end;
    inner.Walk.visit_mod_item_pre id params item
  in

  let visit_mod_item_post
      (id:Ast.ident)
      (params:(Ast.ty_limit * Ast.ident) array)
      (item:Ast.mod_item)
      : unit =
    inner.Walk.visit_mod_item_pre id params item;
    if Hashtbl.mem cx.ctxt_item_files item.id
    then
      begin
        finish_cu_and_compose_headers ()
      end
    else ()
  in

    { inner with
        Walk.visit_mod_item_pre = visit_mod_item_pre;
        Walk.visit_mod_item_post = visit_mod_item_post }
;;


let process_crate
    (cx:ctxt)
    (items:Ast.mod_items)
    : debug_records =

  let cu_aranges = ref [] in
  let cu_pubnames = ref [] in
  let cu_infos = ref [] in
  let cu_abbrevs = ref [] in
  let cu_lines = ref [] in
  let cu_frames = ref [] in

  let debug_aranges_fixup = new_fixup "debug_aranges section" in
  let debug_pubnames_fixup = new_fixup "debug_pubnames section" in
  let debug_info_fixup = new_fixup "debug_info section" in
  let debug_abbrev_fixup = new_fixup "debug_abbrev section" in
  let debug_line_fixup = new_fixup "debug_line section" in
  let debug_frame_fixup = new_fixup "debug_frame section" in

  let passes =
    [|
      dwarf_visitor cx Walk.empty_visitor
        cu_aranges cu_pubnames
        cu_infos cu_abbrevs
        cu_lines cu_frames
    |];
  in

    log cx "emitting DWARF records";
    run_passes cx passes (log cx "%s") items;
    {
      debug_aranges = SEQ (Array.of_list (List.rev (!cu_aranges)));
      debug_pubnames = SEQ (Array.of_list (List.rev (!cu_pubnames)));
      debug_info = SEQ (Array.of_list (List.rev (!cu_infos)));
      debug_abbrev = SEQ (Array.of_list (List.rev (!cu_abbrevs)));
      debug_line = SEQ (Array.of_list (List.rev (!cu_lines)));
      debug_frame = SEQ (Array.of_list (List.rev (!cu_frames)));

      debug_aranges_fixup = debug_aranges_fixup;
      debug_pubnames_fixup = debug_pubnames_fixup;
      debug_info_fixup = debug_info_fixup;
      debug_abbrev_fixup = debug_abbrev_fixup;
      debug_line_fixup = debug_line_fixup;
      debug_frame_fixup = debug_frame_fixup;
    }
;;

(*
 * Local Variables:
 * fill-column: 70;
 * indent-tabs-mode: nil
 * buffer-file-coding-system: utf-8-unix
 * compile-command: "make -k -C .. 2>&1 | sed -e 's/\\/x\\//x:\\//g'";
 * End:
 *)

