*&---------------------------------------------------------------------*
*& Program: ZSUBROUTINE_CALL_GRAPH
*& Desc   : Scan ABAP program, build subroutine call graph via HTML
*&          Features: Call graph, Source viewer, Export MD for AI context
*&---------------------------------------------------------------------*
PROGRAM zsubroutine_call_graph.

"----------------------------------------------------------------------
" Types
"----------------------------------------------------------------------
TYPES:
  BEGIN OF ty_call,
    caller TYPE string,
    callee TYPE string,
  END OF ty_call,
  BEGIN OF ty_form,
    name      TYPE string,
    has_calls TYPE abap_bool,
  END OF ty_form,
  BEGIN OF ty_form_src,
    form_name TYPE string,
    src_line  TYPE string,
  END OF ty_form_src,
  BEGIN OF ty_data_decl,
    name TYPE string,
    kind TYPE string,
    def  TYPE string,
  END OF ty_data_decl,
  BEGIN OF ty_table_field,
    tabname   TYPE tabname,
    fieldname TYPE fieldname,
    datatype  TYPE datatype_d,
    leng      TYPE ddleng,
    decimals  TYPE decimals,
    keyflag   TYPE keyflag,
    ddtext    TYPE ddtext,
  END OF ty_table_field.

"----------------------------------------------------------------------
" Global data
"----------------------------------------------------------------------
DATA:
  gt_scanned_progs TYPE TABLE OF programm,
  gt_calls         TYPE TABLE OF ty_call,
  gt_forms         TYPE TABLE OF ty_form,
  gt_form_src      TYPE TABLE OF ty_form_src,
  gt_data_decls    TYPE TABLE OF ty_data_decl,
  gt_sel_screen    TYPE TABLE OF ty_data_decl,
  gt_db_tables     TYPE TABLE OF string,
  gt_table_fields  TYPE TABLE OF ty_table_field,
  gv_progname      TYPE programm.

"----------------------------------------------------------------------
" Selection screen
"----------------------------------------------------------------------
SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.
PARAMETERS: p_prog TYPE programm OBLIGATORY.
SELECTION-SCREEN END OF BLOCK b1.

"----------------------------------------------------------------------
" Main
"----------------------------------------------------------------------
START-OF-SELECTION.
  gv_progname = p_prog.
  PERFORM f_scan_program.
  PERFORM f_display_html.

"======================================================================
" FORM: f_scan_program
"======================================================================
FORM f_scan_program.
  PERFORM f_read_source USING gv_progname.
  LOOP AT gt_scanned_progs INTO DATA(lv_p).
    PERFORM f_scan_globals USING lv_p.
  ENDLOOP.
  PERFORM f_read_table_structures.
ENDFORM.

"======================================================================
" FORM: f_read_source
" Scan FORMs, event blocks, PERFORM calls, INCLUDEs (recursive)
"======================================================================
FORM f_read_source USING iv_prog TYPE programm.
  DATA:
    lt_source   TYPE TABLE OF string,
    lv_line     TYPE string,
    lv_upper    TYPE string,
    lv_current  TYPE string,
    lv_callee   TYPE string,
    lv_incl     TYPE programm,
    ls_form     TYPE ty_form,
    ls_call     TYPE ty_call,
    ls_fsrc     TYPE ty_form_src,
    lv_token    TYPE string,
    lv_in_form  TYPE abap_bool,
    lv_block    TYPE string,
    lv_ctx      TYPE string,
    lv_new_block TYPE string,
    lv_suffix   TYPE string,
    lv_typeref  TYPE string.

  " Avoid re-scanning same include
  READ TABLE gt_scanned_progs WITH KEY table_line = iv_prog
    TRANSPORTING NO FIELDS.
  IF sy-subrc = 0. RETURN. ENDIF.
  APPEND iv_prog TO gt_scanned_progs.

  READ REPORT iv_prog INTO lt_source.
  IF sy-subrc <> 0. RETURN. ENDIF.

  LOOP AT lt_source INTO lv_line.
    lv_upper = to_upper( lv_line ).
    CONDENSE lv_upper.

    "--- INCLUDE → recurse
    IF lv_upper CP 'INCLUDE *'.
      SPLIT lv_upper AT ' ' INTO TABLE DATA(lt_tok).
      DELETE lt_tok WHERE table_line IS INITIAL.
      READ TABLE lt_tok INDEX 2 INTO lv_token.
      IF sy-subrc = 0.
        FIND REGEX '^(\w+)' IN lv_token SUBMATCHES lv_incl.
        IF lv_incl IS NOT INITIAL.
          PERFORM f_read_source USING lv_incl.
        ENDIF.
      ENDIF.
      CONTINUE.
    ENDIF.

    "--- FORM
    IF lv_upper CP 'FORM *'.
      CLEAR lv_block.
      SPLIT lv_upper AT ' ' INTO TABLE lt_tok.
      DELETE lt_tok WHERE table_line IS INITIAL.
      READ TABLE lt_tok INDEX 2 INTO lv_token.
      IF sy-subrc = 0.
        FIND REGEX '^(\w+)' IN lv_token SUBMATCHES lv_token.
        lv_current = lv_token.
        lv_in_form = abap_true.
        READ TABLE gt_forms WITH KEY name = lv_current
          TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          CLEAR ls_form.
          ls_form-name = lv_current.
          APPEND ls_form TO gt_forms.
        ENDIF.
      ENDIF.
      IF lv_current IS NOT INITIAL.
        CLEAR ls_fsrc.
        ls_fsrc-form_name = lv_current.
        ls_fsrc-src_line  = lv_line.
        APPEND ls_fsrc TO gt_form_src.
      ENDIF.
      CONTINUE.
    ENDIF.

    "--- ENDFORM
    IF lv_upper CP 'ENDFORM*'.
      IF lv_current IS NOT INITIAL.
        CLEAR ls_fsrc.
        ls_fsrc-form_name = lv_current.
        ls_fsrc-src_line  = lv_line.
        APPEND ls_fsrc TO gt_form_src.
      ENDIF.
      CLEAR lv_current.
      lv_in_form = abap_false.
      CONTINUE.
    ENDIF.

    "--- ENDMODULE
    IF lv_upper CP 'ENDMODULE*'.
      IF lv_block IS NOT INITIAL.
        CLEAR ls_fsrc.
        ls_fsrc-form_name = lv_block.
        ls_fsrc-src_line  = lv_line.
        APPEND ls_fsrc TO gt_form_src.
        CLEAR lv_block.
      ENDIF.
      CONTINUE.
    ENDIF.

    "--- EVENT BLOCKS & MODULE (only outside FORM)
    IF lv_in_form = abap_false.
      CLEAR lv_new_block.

      IF lv_upper CP 'START-OF-SELECTION*'.
        lv_new_block = 'START_OF_SELECTION'.
      ELSEIF lv_upper CP 'END-OF-SELECTION*'.
        lv_new_block = 'END_OF_SELECTION'.
      ELSEIF lv_upper CP 'INITIALIZATION*'.
        lv_new_block = 'INITIALIZATION'.
      ELSEIF lv_upper CP 'AT USER-COMMAND*'.
        lv_new_block = 'AT_USER_COMMAND'.
      ELSEIF lv_upper CP 'AT LINE-SELECTION*'.
        lv_new_block = 'AT_LINE_SELECTION'.
      ELSEIF lv_upper CP 'TOP-OF-PAGE*'.
        lv_new_block = 'TOP_OF_PAGE'.
      ELSEIF lv_upper CP 'END-OF-PAGE*'.
        lv_new_block = 'END_OF_PAGE'.
      ELSEIF lv_upper CP 'AT SELECTION-SCREEN*'.
        DATA(lv_kw_len) = strlen( 'AT SELECTION-SCREEN' ).
        IF strlen( lv_upper ) > lv_kw_len.
          lv_suffix = lv_upper+lv_kw_len.
          CONDENSE lv_suffix.
          SPLIT lv_suffix AT ' ' INTO TABLE DATA(lt_suf).
          DELETE lt_suf WHERE table_line IS INITIAL.
          CONCATENATE LINES OF lt_suf INTO lv_suffix SEPARATED BY '_'.
          lv_new_block = 'AT_SELECTION_SCREEN_' && lv_suffix.
        ELSE.
          lv_new_block = 'AT_SELECTION_SCREEN'.
        ENDIF.
        CLEAR lv_suffix.
      ENDIF.

      " MODULE xxx OUTPUT / MODULE xxx INPUT
      IF lv_upper CP 'MODULE * OUTPUT' OR lv_upper CP 'MODULE * INPUT'.
        SPLIT lv_upper AT ' ' INTO TABLE lt_tok.
        DELETE lt_tok WHERE table_line IS INITIAL.
        READ TABLE lt_tok INDEX 2 INTO lv_token.
        READ TABLE lt_tok INDEX 3 INTO DATA(lv_mod_type).
        IF sy-subrc = 0 AND lv_token IS NOT INITIAL.
          FIND REGEX '^(\w+)' IN lv_token SUBMATCHES lv_token.
          lv_new_block = 'MODULE_' && lv_token && '_' && lv_mod_type.
        ENDIF.
      ENDIF.

      IF lv_new_block IS NOT INITIAL AND lv_new_block <> lv_block.
        lv_block = lv_new_block.
        READ TABLE gt_forms WITH KEY name = lv_block
          TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          CLEAR ls_form.
          ls_form-name = lv_block.
          APPEND ls_form TO gt_forms.
        ENDIF.
        CLEAR ls_fsrc.
        ls_fsrc-form_name = lv_block.
        ls_fsrc-src_line  = lv_line.
        APPEND ls_fsrc TO gt_form_src.
        CONTINUE.
      ENDIF.
    ENDIF.

    "--- Detect TYPE TABLE OF / TYPE Z* → collect custom table/type names
    CLEAR lv_typeref.
    FIND REGEX '\bTYPE\s+TABLE\s+OF\s+(\w+)' IN lv_upper SUBMATCHES lv_typeref.
    IF sy-subrc <> 0.
      FIND REGEX '\bLIKE\s+TABLE\s+OF\s+(\w+)' IN lv_upper SUBMATCHES lv_typeref.
    ENDIF.
    IF sy-subrc <> 0.
      FIND REGEX '\bTYPE\s+(Z\w+|Y\w+)' IN lv_upper SUBMATCHES lv_typeref.
    ENDIF.
    IF sy-subrc <> 0.
      FIND REGEX '\bLIKE\s+(Z\w+|Y\w+)' IN lv_upper SUBMATCHES lv_typeref.
    ENDIF.
    IF lv_typeref IS NOT INITIAL.
      TRANSLATE lv_typeref TO UPPER CASE.
      IF ( lv_typeref CP 'Z*' OR lv_typeref CP 'Y*' )
      AND strlen( lv_typeref ) >= 3.
        READ TABLE gt_db_tables WITH KEY table_line = lv_typeref
          TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0.
          APPEND lv_typeref TO gt_db_tables.
        ENDIF.
      ENDIF.
    ENDIF.

    "--- Determine current context
    CLEAR lv_ctx.
    IF lv_in_form = abap_true AND lv_current IS NOT INITIAL.
      lv_ctx = lv_current.
    ELSEIF lv_in_form = abap_false AND lv_block IS NOT INITIAL.
      lv_ctx = lv_block.
    ENDIF.

    "--- Save source line
    IF lv_ctx IS NOT INITIAL.
      CLEAR ls_fsrc.
      ls_fsrc-form_name = lv_ctx.
      ls_fsrc-src_line  = lv_line.
      APPEND ls_fsrc TO gt_form_src.
    ENDIF.

    "--- Detect PERFORM
    IF lv_ctx IS NOT INITIAL AND lv_upper CP 'PERFORM *'.
      SPLIT lv_upper AT ' ' INTO TABLE lt_tok.
      DELETE lt_tok WHERE table_line IS INITIAL.
      READ TABLE lt_tok INDEX 2 INTO lv_token.
      IF sy-subrc = 0.
        FIND REGEX '^(\w+)' IN lv_token SUBMATCHES lv_callee.
        IF lv_callee IS NOT INITIAL AND lv_callee <> lv_ctx.
          READ TABLE gt_forms WITH KEY name = lv_callee
            TRANSPORTING NO FIELDS.
          IF sy-subrc <> 0.
            CLEAR ls_form.
            ls_form-name = lv_callee.
            APPEND ls_form TO gt_forms.
          ENDIF.
          READ TABLE gt_calls WITH KEY caller = lv_ctx callee = lv_callee
            TRANSPORTING NO FIELDS.
          IF sy-subrc <> 0.
            CLEAR ls_call.
            ls_call-caller = lv_ctx.
            ls_call-callee = lv_callee.
            APPEND ls_call TO gt_calls.
          ENDIF.
          READ TABLE gt_forms WITH KEY name = lv_ctx INTO ls_form.
          IF sy-subrc = 0.
            ls_form-has_calls = abap_true.
            MODIFY gt_forms FROM ls_form TRANSPORTING has_calls
              WHERE name = lv_ctx.
          ENDIF.
        ENDIF.
      ENDIF.
    ENDIF.

  ENDLOOP.
ENDFORM.

"======================================================================
" FORM: f_scan_globals  (statement-accumulator approach)
" Gom từng ABAP statement hoàn chỉnh (kết thúc '.') vào buffer
" rồi parse 1 lần → đúng với mọi multi-line / colon syntax
" State machine: TOP / FORM / EVENT
"======================================================================
FORM f_scan_globals USING iv_prog TYPE programm.
  DATA:
    lt_source   TYPE TABLE OF string,
    lv_line     TYPE string,
    lv_upper    TYPE string,
    lv_state    TYPE string,
    lv_stmt_raw TYPE string,
    lv_stmt_up  TYPE string,
    lv_from_pos TYPE i,
    lv_after    TYPE string,
    lv_tabname  TYPE string,
    lv_work     TYPE string,
    lv_last     TYPE c,
    lv_len      TYPE i,
    lv_ends     TYPE abap_bool.

  READ REPORT iv_prog INTO lt_source.
  IF sy-subrc <> 0. RETURN. ENDIF.

  lv_state = 'TOP'.

  LOOP AT lt_source INTO lv_line.
    lv_upper = to_upper( lv_line ).
    CONDENSE lv_upper.

    IF lv_upper IS INITIAL. CONTINUE. ENDIF.
    IF lv_upper(1) = '*'. CONTINUE. ENDIF.

    "--- State transitions
    IF lv_upper CP 'FORM *'
    OR lv_upper CP 'MODULE * OUTPUT'
    OR lv_upper CP 'MODULE * INPUT'.
      lv_state = 'FORM'. CLEAR: lv_stmt_raw, lv_stmt_up. CONTINUE.
    ENDIF.
    IF lv_upper CP 'ENDFORM*' OR lv_upper CP 'ENDMODULE*'.
      lv_state = 'TOP'. CLEAR: lv_stmt_raw, lv_stmt_up. CONTINUE.
    ENDIF.
    IF lv_upper CP 'START-OF-SELECTION*' OR lv_upper CP 'END-OF-SELECTION*'
    OR lv_upper CP 'INITIALIZATION*'     OR lv_upper CP 'AT SELECTION-SCREEN*'
    OR lv_upper CP 'AT USER-COMMAND*'    OR lv_upper CP 'AT LINE-SELECTION*'
    OR lv_upper CP 'TOP-OF-PAGE*'        OR lv_upper CP 'END-OF-PAGE*'.
      lv_state = 'EVENT'. CLEAR: lv_stmt_raw, lv_stmt_up. CONTINUE.
    ENDIF.

    "--- Collect DB table names from FROM (ALL states)
    FIND 'FROM' IN lv_upper MATCH OFFSET lv_from_pos.
    IF sy-subrc = 0.
      lv_after = lv_upper+lv_from_pos.
      SPLIT lv_after AT ' ' INTO TABLE DATA(lt_tmp).
      DELETE lt_tmp WHERE table_line IS INITIAL.
      READ TABLE lt_tmp INDEX 2 INTO lv_tabname.
      IF sy-subrc = 0 AND lv_tabname IS NOT INITIAL.
        FIND REGEX '^[@~]?(\w+)' IN lv_tabname SUBMATCHES lv_tabname.
        TRANSLATE lv_tabname TO UPPER CASE.
        IF lv_tabname IS NOT INITIAL
        AND lv_tabname <> 'FROM' AND lv_tabname <> 'TABLE'
        AND lv_tabname <> 'ENTRIES' AND lv_tabname <> 'SCREEN'
        AND lv_tabname <> 'SELECT' AND strlen( lv_tabname ) >= 3.
          READ TABLE gt_db_tables WITH KEY table_line = lv_tabname
            TRANSPORTING NO FIELDS.
          IF sy-subrc <> 0. APPEND lv_tabname TO gt_db_tables. ENDIF.
        ENDIF.
      ENDIF.
    ENDIF.

    " Only accumulate declarations at TOP
    IF lv_state <> 'TOP'. CONTINUE. ENDIF.

    " Skip lines that cannot start a declaration block and have no pending
    " (avoid accumulating PERFORM, CALL etc. at top level)
    IF lv_stmt_raw IS INITIAL.
      IF NOT (    lv_upper CP 'DATA*'
               OR lv_upper CP 'TYPES*'
               OR lv_upper CP 'CONSTANTS*'
               OR lv_upper CP 'PARAMETERS*'
               OR lv_upper CP 'SELECT-OPTIONS*'
               OR lv_upper CP 'SELECTION-SCREEN*' ).
        CONTINUE.
      ENDIF.
    ENDIF.

    "--- Accumulate statement
    IF lv_stmt_raw IS INITIAL.
      lv_stmt_raw = lv_line.
      lv_stmt_up  = lv_upper.
    ELSE.
      CONCATENATE lv_stmt_raw ' ' lv_line  INTO lv_stmt_raw.
      CONCATENATE lv_stmt_up  ' ' lv_upper INTO lv_stmt_up.
    ENDIF.

    "--- Check statement ends (last non-comment char = '.')
    lv_work = lv_stmt_up.
    FIND REGEX '"[^"]*$' IN lv_work.
    IF sy-subrc = 0. REPLACE REGEX '"[^"]*$' IN lv_work WITH ''. ENDIF.
    CONDENSE lv_work.
    lv_ends = abap_false.
    IF lv_work IS NOT INITIAL.
      lv_len  = strlen( lv_work ) - 1.
      lv_last = lv_work+lv_len(1).
      IF lv_last = '.'. lv_ends = abap_true. ENDIF.
    ENDIF.

    IF lv_ends = abap_false. CONTINUE. ENDIF.

    "--- Parse complete statement
    PERFORM f_parse_statement USING lv_stmt_up lv_stmt_raw.
    CLEAR: lv_stmt_raw, lv_stmt_up.

  ENDLOOP.
ENDFORM.

"======================================================================
" FORM: f_parse_statement
" Parse 1 complete ABAP statement accumulated from 1 or more lines
"======================================================================
FORM f_parse_statement
  USING iv_stmt_up  TYPE string
        iv_stmt_raw TYPE string.

  DATA:
    lv_body     TYPE string,
    lv_kind     TYPE string,
    lv_work     TYPE string,
    lv_name     TYPE string,
    lv_type_ref TYPE string,
    lv_last     TYPE c,
    lv_len      TYPE i,
    ls_decl     TYPE ty_data_decl.

  "--- SELECTION-SCREEN structural lines
  IF iv_stmt_up CP 'SELECTION-SCREEN*'.
    CLEAR ls_decl.
    ls_decl-kind = 'SELECTION-SCREEN'.
    ls_decl-name = iv_stmt_up.
    ls_decl-def  = iv_stmt_raw.
    APPEND ls_decl TO gt_sel_screen.
    RETURN.
  ENDIF.

  "--- Determine declaration kind
  IF     iv_stmt_up CP 'PARAMETERS*'.    lv_kind = 'PARAMETER'.
  ELSEIF iv_stmt_up CP 'SELECT-OPTIONS*'. lv_kind = 'SELECT-OPTION'.
  ELSEIF iv_stmt_up CP 'DATA*'.          lv_kind = 'DATA'.
  ELSEIF iv_stmt_up CP 'TYPES*'.         lv_kind = 'TYPES'.
  ELSEIF iv_stmt_up CP 'CONSTANTS*'.     lv_kind = 'CONSTANTS'.
  ELSE. RETURN.
  ENDIF.

  "--- Strip keyword [+ colon] to get declaration body
  lv_body = iv_stmt_up.
  FIND ':' IN lv_body.
  IF sy-subrc = 0.
    " Colon syntax: take everything after first colon
    FIND REGEX '^[^:]+:(.*)$' IN lv_body SUBMATCHES lv_body.
  ELSE.
    " No colon: strip first token (keyword)
    SPLIT lv_body AT ' ' INTO TABLE DATA(lt_kw).
    DELETE lt_kw INDEX 1.
    DELETE lt_kw WHERE table_line IS INITIAL.
    CONCATENATE LINES OF lt_kw INTO lv_body SEPARATED BY ' '.
  ENDIF.

  " Strip trailing dot
  CONDENSE lv_body.
  IF lv_body IS INITIAL. RETURN. ENDIF.
  lv_len = strlen( lv_body ) - 1.
  lv_last = lv_body+lv_len(1).
  IF lv_last = '.'. lv_body = lv_body(lv_len). CONDENSE lv_body. ENDIF.

  "--- Split by comma → each segment = one variable declaration
  SPLIT lv_body AT ',' INTO TABLE DATA(lt_items).

  LOOP AT lt_items INTO lv_work.
    CONDENSE lv_work.
    IF lv_work IS INITIAL. CONTINUE. ENDIF.

    " Strip trailing dot (safety)
    lv_len = strlen( lv_work ) - 1.
    IF lv_len >= 0.
      lv_last = lv_work+lv_len(1).
      IF lv_last = '.'. lv_work = lv_work(lv_len). CONDENSE lv_work. ENDIF.
    ENDIF.
    IF lv_work IS INITIAL. CONTINUE. ENDIF.

    " Variable name = first token
    SPLIT lv_work AT ' ' INTO TABLE DATA(lt_w).
    DELETE lt_w WHERE table_line IS INITIAL.
    READ TABLE lt_w INDEX 1 INTO lv_name.
    FIND REGEX '^(\w+)' IN lv_name SUBMATCHES lv_name.
    IF lv_name IS INITIAL. CONTINUE. ENDIF.

    " Extract Z/Y type ref for table structure lookup
    CLEAR lv_type_ref.
    FIND REGEX '\bTYPE\s+TABLE\s+OF\s+(\w+)' IN lv_work SUBMATCHES lv_type_ref.
    IF sy-subrc <> 0.
      FIND REGEX '\bLIKE\s+TABLE\s+OF\s+(\w+)' IN lv_work SUBMATCHES lv_type_ref.
    ENDIF.
    IF sy-subrc <> 0.
      FIND REGEX '\bTYPE\s+(Z\w+|Y\w+)' IN lv_work SUBMATCHES lv_type_ref.
    ENDIF.
    IF sy-subrc <> 0.
      FIND REGEX '\bLIKE\s+(Z\w+|Y\w+)' IN lv_work SUBMATCHES lv_type_ref.
    ENDIF.
    IF lv_type_ref IS NOT INITIAL.
      TRANSLATE lv_type_ref TO UPPER CASE.
      IF ( lv_type_ref CP 'Z*' OR lv_type_ref CP 'Y*' )
      AND strlen( lv_type_ref ) >= 3.
        READ TABLE gt_db_tables WITH KEY table_line = lv_type_ref
          TRANSPORTING NO FIELDS.
        IF sy-subrc <> 0. APPEND lv_type_ref TO gt_db_tables. ENDIF.
      ENDIF.
    ENDIF.

    " Store — use full accumulated raw statement as def (clean display)
    IF lv_kind = 'PARAMETER' OR lv_kind = 'SELECT-OPTION'.
      READ TABLE gt_sel_screen WITH KEY name = lv_name
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        CLEAR ls_decl.
        ls_decl-kind = lv_kind.
        ls_decl-name = lv_name.
        ls_decl-def  = iv_stmt_raw.
        APPEND ls_decl TO gt_sel_screen.
      ENDIF.
    ELSE.
      READ TABLE gt_data_decls WITH KEY name = lv_name
        TRANSPORTING NO FIELDS.
      IF sy-subrc <> 0.
        CLEAR ls_decl.
        ls_decl-kind = lv_kind.
        ls_decl-name = lv_name.
        ls_decl-def  = lv_work.
        APPEND ls_decl TO gt_data_decls.
      ENDIF.
    ENDIF.
  ENDLOOP.
ENDFORM.

"======================================================================
" FORM: f_read_table_structures
" Read DD field definitions for all detected DB tables
"======================================================================
FORM f_read_table_structures.
  DATA ls_field TYPE ty_table_field.

  LOOP AT gt_db_tables INTO DATA(lv_tab).
    " Check table/view/structure exists in DD (active)
    SELECT SINGLE tabname FROM dd02l
      WHERE tabname  = @lv_tab
        AND as4local = 'A'
      INTO @DATA(lv_check).
    IF sy-subrc <> 0. CONTINUE. ENDIF.

    " Read fields with description
    " Note: dd03t may not have as4local on all systems → join without it
    SELECT f~tabname, f~fieldname, f~datatype, f~leng, f~decimals, f~keyflag,
           t~ddtext
      FROM dd03l AS f
      LEFT OUTER JOIN dd03t AS t
        ON  t~tabname    = f~tabname
        AND t~fieldname  = f~fieldname
        AND t~ddlanguage = @sy-langu
      WHERE f~tabname  = @lv_tab
        AND f~as4local = 'A'
        AND f~fieldname NOT LIKE '.%'
      ORDER BY f~position
      INTO TABLE @DATA(lt_fields).

    LOOP AT lt_fields INTO DATA(ls_f).
      CLEAR ls_field.
      ls_field-tabname   = ls_f-tabname.
      ls_field-fieldname = ls_f-fieldname.
      ls_field-datatype  = ls_f-datatype.
      ls_field-leng      = ls_f-leng.
      ls_field-decimals  = ls_f-decimals.
      ls_field-keyflag   = ls_f-keyflag.
      ls_field-ddtext    = ls_f-ddtext.
      APPEND ls_field TO gt_table_fields.
    ENDLOOP.
  ENDLOOP.
ENDFORM.

"======================================================================
" FORM: f_build_src_json
" Build JSON map: {"FORM_A":"line1\nline2",...}
"======================================================================
FORM f_build_src_json CHANGING cv_json TYPE string.
  DATA:
    lv_prev_form TYPE string,
    lv_src_block TYPE string,
    lv_escaped   TYPE string,
    lv_comma     TYPE string.

  cv_json = '{'.
  CLEAR: lv_prev_form, lv_src_block, lv_comma.

  LOOP AT gt_form_src INTO DATA(ls).
    IF ls-form_name <> lv_prev_form.
      IF lv_prev_form IS NOT INITIAL.
        PERFORM f_escape_json USING lv_src_block CHANGING lv_escaped.
        CONCATENATE cv_json lv_comma '"' lv_prev_form '":"' lv_escaped '"'
          INTO cv_json.
        lv_comma = ','.
      ENDIF.
      lv_prev_form = ls-form_name.
      CLEAR lv_src_block.
    ENDIF.
    IF lv_src_block IS INITIAL.
      lv_src_block = ls-src_line.
    ELSE.
      CONCATENATE lv_src_block cl_abap_char_utilities=>newline ls-src_line
        INTO lv_src_block.
    ENDIF.
  ENDLOOP.

  " Flush last block
  IF lv_prev_form IS NOT INITIAL.
    PERFORM f_escape_json USING lv_src_block CHANGING lv_escaped.
    CONCATENATE cv_json lv_comma '"' lv_prev_form '":"' lv_escaped '"'
      INTO cv_json.
  ENDIF.

  CONCATENATE cv_json '}' INTO cv_json.
ENDFORM.

"======================================================================
" FORM: f_build_context_json
" Build JSON: {sel_screen:[...], globals:[...], tables:{TAB:[fields]}}
"======================================================================
FORM f_build_context_json CHANGING cv_json TYPE string.
  DATA:
    lv_comma     TYPE string,
    lv_tab_comma TYPE string,
    lv_esc       TYPE string,
    lv_name_esc  TYPE string,
    lv_kind_esc  TYPE string,
    lv_prev_tab  TYPE string,
    lv_tab       TYPE string,
    lv_fn        TYPE string,
    lv_dt        TYPE string,
    lv_txt       TYPE string,
    lv_key       TYPE string,
    lv_len       TYPE string.

  cv_json = '{'.

  "--- Selection screen
  CONCATENATE cv_json '"sel_screen":[' INTO cv_json.
  CLEAR lv_comma.
  LOOP AT gt_sel_screen INTO DATA(ls_sel).
    PERFORM f_escape_json USING ls_sel-def  CHANGING lv_esc.
    PERFORM f_escape_json USING ls_sel-name CHANGING lv_name_esc.
    PERFORM f_escape_json USING ls_sel-kind CHANGING lv_kind_esc.
    CONCATENATE cv_json lv_comma
      '{"kind":"' lv_kind_esc '","name":"' lv_name_esc '","def":"' lv_esc '"}'
      INTO cv_json.
    lv_comma = ','.
  ENDLOOP.
  CONCATENATE cv_json '],' INTO cv_json.

  "--- Global declarations
  CONCATENATE cv_json '"globals":[' INTO cv_json.
  CLEAR lv_comma.
  LOOP AT gt_data_decls INTO DATA(ls_decl).
    PERFORM f_escape_json USING ls_decl-def  CHANGING lv_esc.
    PERFORM f_escape_json USING ls_decl-name CHANGING lv_name_esc.
    PERFORM f_escape_json USING ls_decl-kind CHANGING lv_kind_esc.
    CONCATENATE cv_json lv_comma
      '{"kind":"' lv_kind_esc '","name":"' lv_name_esc '","def":"' lv_esc '"}'
      INTO cv_json.
    lv_comma = ','.
  ENDLOOP.
  CONCATENATE cv_json '],' INTO cv_json.

  "--- Table structures
  CONCATENATE cv_json '"tables":{' INTO cv_json.
  CLEAR: lv_comma, lv_prev_tab.

  LOOP AT gt_table_fields INTO DATA(ls_f).
    lv_tab = ls_f-tabname.
    IF lv_tab <> lv_prev_tab.
      IF lv_prev_tab IS NOT INITIAL.
        CONCATENATE cv_json ']' INTO cv_json.
        lv_comma = ','.
      ENDIF.
      CONCATENATE cv_json lv_comma '"' lv_tab '":[' INTO cv_json.
      lv_prev_tab = lv_tab.
      CLEAR lv_tab_comma.
    ENDIF.

    lv_fn  = ls_f-fieldname.
    lv_dt  = ls_f-datatype.
    lv_txt = ls_f-ddtext.
    PERFORM f_escape_json USING lv_txt CHANGING lv_txt.
    IF ls_f-keyflag = 'X'. lv_key = 'true'. ELSE. lv_key = 'false'. ENDIF.
    " Convert ddleng (packed/numeric) to plain integer string, strip leading zeros
    DATA lv_leng_i TYPE i.
    lv_leng_i = ls_f-leng.
    lv_len = lv_leng_i.

    CONCATENATE cv_json lv_tab_comma
      '{"f":"' lv_fn '","t":"' lv_dt '","l":' lv_len ',"k":' lv_key ',"d":"' lv_txt '"}'
      INTO cv_json.
    lv_tab_comma = ','.
  ENDLOOP.

  IF lv_prev_tab IS NOT INITIAL.
    CONCATENATE cv_json ']' INTO cv_json.
  ENDIF.
  CONCATENATE cv_json '}}' INTO cv_json.
ENDFORM.

"======================================================================
" FORM: f_escape_json
"======================================================================
FORM f_escape_json USING iv_raw TYPE string CHANGING cv_out TYPE string.
  cv_out = iv_raw.
  REPLACE ALL OCCURRENCES OF '\' IN cv_out WITH '\\'.
  REPLACE ALL OCCURRENCES OF '"' IN cv_out WITH '\"'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>newline     IN cv_out WITH '\n'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>cr_lf       IN cv_out WITH '\n'.
  REPLACE ALL OCCURRENCES OF cl_abap_char_utilities=>horizontal_tab IN cv_out WITH '  '.
ENDFORM.

"======================================================================
" FORM: f_display_html
"======================================================================
FORM f_display_html.
  IF gt_forms IS INITIAL.
    MESSAGE 'Khong tim thay FORM nao trong program!' TYPE 'W'.
    RETURN.
  ENDIF.
  CALL SCREEN 100.
ENDFORM.

"======================================================================
" FORM: f_build_html
"======================================================================
FORM f_build_html
  USING iv_nodes TYPE string
        iv_edges TYPE string
        iv_src   TYPE string
        iv_ctx   TYPE string
        iv_prog  TYPE program
  CHANGING cv_html TYPE string.

  DATA lv_prog TYPE string.
  lv_prog = iv_prog.

  cv_html =
    `<!DOCTYPE html><html><head><meta charset="UTF-8">` &&
    `<title>Call Graph</title>` &&
    `<script src="https://cdnjs.cloudflare.com/ajax/libs/vis/4.21.0/vis.min.js"></script>` &&
    `<meta name="viewport" content="width=device-width,initial-scale=1.0,maximum-scale=1.0">` &&
    `<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/vis/4.21.0/vis.min.css">` &&
    `<style>` &&
    `*{margin:0;padding:0;box-sizing:border-box}` &&
    `body{font-family:Arial,sans-serif;background:#f5f5f5;display:flex;flex-direction:column;height:100vh}` &&
    `#header{background:#1565c0;color:#fff;padding:8px 16px;display:flex;align-items:center;gap:12px}` &&
    `#header h2{font-size:14px;font-weight:600}` &&
    `#header span{font-size:12px;background:rgba(255,255,255,.2);padding:2px 10px;border-radius:10px}` &&
    `#mynetwork{flex:1;background:#fff;overflow:hidden}` &&
    `#toolbar{background:#fff;border-bottom:1px solid #ddd;padding:6px 12px;display:flex;` &&
    `gap:8px;align-items:center;flex-wrap:wrap}` &&
    `#toolbar label{font-size:12px;color:#555}` &&
    `#toolbar select{font-size:12px;padding:3px 7px;border:1px solid #ccc;border-radius:4px}` &&
    `#toolbar button{font-size:12px;padding:3px 10px;border:1px solid #1565c0;border-radius:4px;` &&
    `background:#1565c0;color:#fff;cursor:pointer}` &&
    `#toolbar button:hover{opacity:.85}` &&
    `#stats{margin-left:auto;font-size:11px;color:#888}` &&
    `#info{position:fixed;right:12px;bottom:12px;background:#fff;border:1px solid #e0e0e0;` &&
    `border-radius:6px;padding:10px 14px;font-size:12px;min-width:200px;display:none;` &&
    `box-shadow:0 2px 8px rgba(0,0,0,.12);max-width:280px;z-index:100}` &&
    `#info h4{font-size:13px;font-weight:600;margin-bottom:6px;color:#1565c0}` &&
    `#info .sec{color:#888;font-size:11px;margin-top:4px}` &&
    `#info .item{color:#333;padding-left:8px;line-height:1.8}` &&
    `.modal-overlay{display:none;position:fixed;inset:0;background:rgba(0,0,0,.55);` &&
    `z-index:1000;align-items:center;justify-content:center}` &&
    `.modal-overlay.open{display:flex}` &&
    `.modal-box{background:#1e1e2e;border-radius:8px;width:75vw;max-width:960px;max-height:85vh;` &&
    `display:flex;flex-direction:column;box-shadow:0 8px 32px rgba(0,0,0,.4);overflow:hidden}` &&
    `.modal-header{background:#12121f;padding:10px 16px;display:flex;align-items:center;` &&
    `justify-content:space-between;border-bottom:1px solid #2e2e4a;gap:8px}` &&
    `.modal-header .title{color:#7ec8e3;font-size:13px;font-weight:600;` &&
    `font-family:"Courier New",monospace;flex:1;min-width:0;overflow:hidden;text-overflow:ellipsis;white-space:nowrap}` &&
    `.badges{display:flex;gap:6px;flex-shrink:0}` &&
    `.badge{font-size:10px;padding:2px 8px;border-radius:10px;font-weight:600}` &&
    `.badge-calls{background:#1565c020;color:#7ec8e3;border:1px solid #1565c060}` &&
    `.badge-callers{background:#38803820;color:#81c784;border:1px solid #38803860}` &&
    `.modal-close{background:none;border:none;color:#888;font-size:18px;cursor:pointer;` &&
    `line-height:1;padding:0 4px;flex-shrink:0}` &&
    `.modal-close:hover{color:#fff}` &&
    `.modal-body{overflow-y:auto;padding:0}` &&
    `pre.code-block{margin:0;padding:14px 18px;font-family:"Courier New",monospace;` &&
    `font-size:12.5px;line-height:1.65;color:#cdd6f4;white-space:pre;tab-size:2}` &&
    `pre.code-block .ln{display:inline-block;width:36px;text-align:right;` &&
    `color:#444466;margin-right:16px;user-select:none;font-size:11px}` &&
    `.kw{color:#cba6f7}.str{color:#a6e3a1}.cmt{color:#6c7086;font-style:italic}.num{color:#fab387}` &&
    `#struct-panel{position:fixed;left:0;top:0;bottom:0;width:300px;background:#fff;` &&
    `border-right:1px solid #ddd;display:none;flex-direction:column;z-index:200;` &&
    `box-shadow:2px 0 8px rgba(0,0,0,.1)}` &&
    `#struct-panel.open{display:flex}` &&
    `#struct-header{background:#263238;color:#fff;padding:8px 12px;display:flex;` &&
    `align-items:center;justify-content:space-between;font-size:12px;font-weight:600}` &&
    `#struct-body{overflow-y:auto;padding:8px;flex:1;font-size:11.5px}` &&
    `.struct-tab{display:flex;border-bottom:1px solid #eee;margin-bottom:8px}` &&
    `.struct-tab button{flex:1;padding:5px;border:none;background:none;font-size:11px;` &&
    `cursor:pointer;border-bottom:2px solid transparent;color:#666}` &&
    `.struct-tab button.active{border-bottom-color:#1565c0;color:#1565c0;font-weight:600}` &&
    `.struct-section{display:none}.struct-section.active{display:block}` &&
    `.decl-item{padding:3px 0;border-bottom:1px solid #f5f5f5;font-family:monospace}` &&
    `.decl-kind{display:inline-block;font-size:9px;padding:1px 5px;border-radius:3px;` &&
    `margin-right:4px;font-weight:600;color:#fff}` &&
    `.kind-data{background:#1565c0}.kind-types{background:#6a1b9a}` &&
    `.kind-parameter{background:#2e7d32}.kind-select-option{background:#e65100}` &&
    `.kind-constants{background:#37474f}.kind-selection-screen{background:#546e7a}` &&
    `.tbl-wrap{margin-bottom:12px}` &&
    `.tbl-name{font-weight:600;color:#1565c0;font-size:12px;margin-bottom:4px;` &&
    `font-family:monospace}` &&
    `.tbl-fields{width:100%;border-collapse:collapse;font-size:10.5px}` &&
    `.tbl-fields th{background:#f5f5f5;padding:2px 5px;text-align:left;` &&
    `border:1px solid #e0e0e0;font-size:10px;color:#555}` &&
    `.tbl-fields td{padding:2px 5px;border:1px solid #f0f0f0;font-family:monospace}` &&
    `.tbl-fields tr.key-row td{background:#e3f2fd;font-weight:600}` &&
    `#mynetwork{flex:1;background:#fff;overflow:hidden;transition:margin-left .2s}` &&
    `</style></head><body>` &&
    `<div id="struct-panel">` &&
    `<div id="struct-header">` &&
    `<span id="struct-title">Declarations</span>` &&
    `<button onclick="closeStruct()" style="background:none;border:none;color:#aaa;` &&
    `font-size:16px;cursor:pointer">&#10005;</button>` &&
    `</div>` &&
    `<div class="struct-tab">` &&
    `<button id="tab-sel" class="active" onclick="switchTab('sel')">Selection Screen</button>` &&
    `<button id="tab-gbl" onclick="switchTab('gbl')">Global DATA</button>` &&
    `<button id="tab-tbl" onclick="switchTab('tbl')">Tables</button>` &&
    `</div>` &&
    `<div id="struct-body">` &&
    `<div id="sec-sel" class="struct-section active"></div>` &&
    `<div id="sec-gbl" class="struct-section"></div>` &&
    `<div id="sec-tbl" class="struct-section"></div>` &&
    `</div>` &&
    `</div>` &&
    `<div id="header">` &&
    `<h2>&#128269; ABAP Subroutine Call Graph</h2>` &&
    `<span>` && lv_prog && `</span>` &&
    `</div>` &&
    `<div id="toolbar">` &&
    `<label>Layout:</label>` &&
    `<select id="layoutSel" onchange="changeLayout()">` &&
    `<option value="hierarchical">Hierarchical</option>` &&
    `<option value="physics">Physics</option>` &&
    `</select>` &&
    `<label>Direction:</label>` &&
    `<select id="dirSel" onchange="changeDir()">` &&
    `<option value="UD">Top-Down</option>` &&
    `<option value="LR">Left-Right</option>` &&
    `</select>` &&
    `<button onclick="fitNetwork()">&#8635; Fit</button>` &&
    `<button onclick="resetInfo()">&#10005; Deselect</button>` &&
    `<button onclick="toggleStruct()" style="background:#37474f;border-color:#37474f">` &&
    `&#128218; Declarations</button>` &&
    `<button onclick="exportMD()" style="background:#2e7d32;border-color:#2e7d32">` &&
    `&#128196; Export MD</button>` &&
    `<span id="stats"></span>` &&
    `</div>` &&
    `<div style="display:flex;flex:1;overflow:hidden">` &&
    `<div id="mynetwork" style="flex:1;background:#fff;overflow:hidden"></div>` &&
    `</div>` &&
    `<div id="info">` &&
    `<h4 id="info-title"></h4>` &&
    `<div class="sec">&#8594; Calls</div>` &&
    `<div id="info-calls" class="item"></div>` &&
    `<div class="sec" style="margin-top:6px">&#8592; Called by</div>` &&
    `<div id="info-callers" class="item"></div>` &&
    `<button onclick="showCode(currentNode)"` &&
    `style="margin-top:10px;width:100%;font-size:12px;padding:5px 0;` &&
    `border:1px solid #1565c0;border-radius:4px;background:#1565c0;color:#fff;cursor:pointer">` &&
    `&#128196; View Source</button>` &&
    `</div>` &&
    `<div id="codeModal" class="modal-overlay" onclick="closeModal(event)">` &&
    `<div class="modal-box">` &&
    `<div class="modal-header">` &&
    `<span class="title" id="modal-title"></span>` &&
    `<div class="badges">` &&
    `<span class="badge badge-calls" id="modal-calls-badge"></span>` &&
    `<span class="badge badge-callers" id="modal-callers-badge"></span>` &&
    `</div>` &&
    `<button class="modal-close"` &&
    `onclick="document.getElementById('codeModal').classList.remove('open')">&#10005;</button>` &&
    `</div>` &&
    `<div class="modal-body"><pre class="code-block" id="modal-code"></pre></div>` &&
    `</div></div>` &&
    `<script>` &&
    `var nodesData=` && iv_nodes && `;` &&
    `var edgesData=` && iv_edges && `;` &&
    `var srcMap=` && iv_src && `;` &&
    `var ctxData=` && iv_ctx && `;` &&
    `var currentNode=null;` &&
    `var rootSet={},callerMap={},calleeMap={};` &&
    `edgesData.forEach(function(e){` &&
    `  (callerMap[e.to]=callerMap[e.to]||[]).push(e.from);` &&
    `  (calleeMap[e.from]=calleeMap[e.from]||[]).push(e.to);` &&
    `});` &&
    `nodesData.forEach(function(n){if(!callerMap[n.id])rootSet[n.id]=1;});` &&
    `var colorMap={` &&
    `  root:{background:'#1565c0',border:'#0d47a1',font:{color:'#fff'}},` &&
    `  leaf:{background:'#e8f5e9',border:'#388e3c',font:{color:'#1b5e20'}},` &&
    `  mid:{background:'#fff8e1',border:'#f57f17',font:{color:'#3e2723'}},` &&
    `  iso:{background:'#f3e5f5',border:'#7b1fa2',font:{color:'#4a148c'}}` &&
    `};` &&
    `var nodes=new vis.DataSet(nodesData.map(function(n){` &&
    `  var isRoot=rootSet[n.id],isLeaf=!calleeMap[n.id];` &&
    `  var hasEdge=callerMap[n.id]||calleeMap[n.id];` &&
    `  var c=isRoot?colorMap.root:isLeaf?colorMap.leaf:hasEdge?colorMap.mid:colorMap.iso;` &&
    `  return{id:n.id,label:n.label,color:c,font:c.font,shape:'box',` &&
    `    title:'Double-click to view source',` &&
    `    borderWidth:1.5,shadow:{enabled:true,size:3,x:2,y:2,color:'rgba(0,0,0,.1)'}};` &&
    `}));` &&
    `var edges=new vis.DataSet(edgesData.map(function(e,i){` &&
    `  return{id:i,from:e.from,to:e.to,arrows:'to',` &&
    `    color:{color:'#90a4ae',highlight:'#1565c0'},width:1};` &&
    `}));` &&
    `var network=new vis.Network(` &&
    `  document.getElementById('mynetwork'),` &&
    `  {nodes:nodes,edges:edges},` &&
    `  {layout:{hierarchical:{enabled:true,direction:'UD',` &&
    `    sortMethod:'directed',nodeSpacing:140,levelSeparation:100}},` &&
    `   physics:{enabled:false},` &&
    `   interaction:{hover:true,tooltipDelay:100},` &&
    `   nodes:{font:{size:12,face:'Courier New'},margin:8,heightConstraint:{minimum:28}}}` &&
    `);` &&
    `document.getElementById('stats').textContent=` &&
    `  nodesData.length+' blocks / '+edgesData.length+' calls';` &&
    `network.on('click',function(p){` &&
    `  if(!p.nodes.length){resetInfo();return;}` &&
    `  var id=p.nodes[0];currentNode=id;` &&
    `  document.getElementById('info-title').textContent=id;` &&
    `  document.getElementById('info-calls').innerHTML=` &&
    `    (calleeMap[id]||[]).join('<br>')||'<i style="color:#bbb">none</i>';` &&
    `  document.getElementById('info-callers').innerHTML=` &&
    `    (callerMap[id]||[]).join('<br>')||'<i style="color:#bbb">none</i>';` &&
    `  document.getElementById('info').style.display='block';` &&
    `  var connected=[id].concat(calleeMap[id]||[]).concat(callerMap[id]||[]);` &&
    `  nodes.update(nodesData.map(function(n){` &&
    `    return{id:n.id,opacity:connected.indexOf(n.id)>=0?1:0.15};` &&
    `  }));` &&
    `  edges.update(edgesData.map(function(e,i){` &&
    `    var rel=e.from===id||e.to===id;` &&
    `    return{id:i,color:{color:rel?'#1565c0':'#ddd'},width:rel?2:1};` &&
    `  }));` &&
    `});` &&
    `network.on('doubleClick',function(p){` &&
    `  if(p.nodes.length)showCode(p.nodes[0]);` &&
    `});` &&
    `network.once('stabilized',function(){network.fit();});` &&
    `/* ════ STRUCT PANEL ════ */` &&
    `function buildStructPanel(){` &&
    `  /* Selection screen */` &&
    `  var selHtml='';` &&
    `  (ctxData.sel_screen||[]).forEach(function(s){` &&
    `    var k=s.kind.toLowerCase().replace(/ /g,'-');` &&
    `    var disp=s.kind==='SELECTION-SCREEN'?escHtml(s.def.trim()):escHtml(s.name);` &&
    `    selHtml+='<div class="decl-item">'+` &&
    `      '<span class="decl-kind kind-'+k+'">'+s.kind+'</span> '+` &&
    `      '<span style="color:#222;font-family:monospace;font-size:11px">'+disp+'</span></div>';` &&
    `  });` &&
    `  document.getElementById('sec-sel').innerHTML=selHtml||'<i style="color:#bbb">none</i>';` &&
    `  /* Global declarations */` &&
    `  var gblHtml='';` &&
    `  (ctxData.globals||[]).forEach(function(g){` &&
    `    var k=g.kind.toLowerCase();` &&
    `    gblHtml+='<div class="decl-item">'+` &&
    `      '<span class="decl-kind kind-'+k+'">'+g.kind+'</span> '+` &&
    `      '<span style="color:#222;font-family:monospace;font-size:11px">'+` &&
    `      escHtml(g.def.trim())+'</span></div>';` &&
    `  });` &&
    `  document.getElementById('sec-gbl').innerHTML=gblHtml||'<i style="color:#bbb">none</i>';` &&
    `  /* Tables */` &&
    `  var tblHtml='';` &&
    `  var tabs=Object.keys(ctxData.tables||{});` &&
    `  if(tabs.length){` &&
    `    tabs.forEach(function(tab){` &&
    `      tblHtml+='<div class="tbl-wrap"><div class="tbl-name">'+tab+'</div>';` &&
    `      tblHtml+='<table class="tbl-fields"><tr>'+` &&
    `        '<th>Field</th><th>Type</th><th>Len</th><th>Description</th></tr>';` &&
    `      (ctxData.tables[tab]||[]).forEach(function(f){` &&
    `        var cls=f.k?'key-row':'';` &&
    `        tblHtml+='<tr class="'+cls+'"><td>'+f.f+'</td><td>'+f.t+` &&
    `          '</td><td>'+f.l+'</td><td>'+escHtml(f.d)+'</td></tr>';` &&
    `      });` &&
    `      tblHtml+='</table></div>';` &&
    `    });` &&
    `  } else {` &&
    `    tblHtml='<i style="color:#bbb">No Z/Y tables detected</i>';` &&
    `  }` &&
    `  document.getElementById('sec-tbl').innerHTML=tblHtml;` &&
    `}` &&
    `var structBuilt=false;` &&
    `function toggleStruct(){` &&
    `  var p=document.getElementById('struct-panel');` &&
    `  if(!structBuilt){buildStructPanel();structBuilt=true;}` &&
    `  p.classList.toggle('open');` &&
    `  network.redraw();network.fit();` &&
    `}` &&
    `function closeStruct(){` &&
    `  document.getElementById('struct-panel').classList.remove('open');` &&
    `  network.redraw();network.fit();` &&
    `}` &&
    `function switchTab(name){` &&
    `  ['sel','gbl','tbl'].forEach(function(t){` &&
    `    document.getElementById('sec-'+t).classList.toggle('active',t===name);` &&
    `    document.getElementById('tab-'+t).classList.toggle('active',t===name);` &&
    `  });` &&
    `}` &&
    `function showCode(id){` &&
    `  if(!id)return;` &&
    `  var raw=srcMap[id]||'(Source not found)';` &&
    `  document.getElementById('modal-title').textContent=id;` &&
    `  document.getElementById('modal-calls-badge').textContent=` &&
    `    (calleeMap[id]||[]).length+' calls';` &&
    `  document.getElementById('modal-callers-badge').textContent=` &&
    `    (callerMap[id]||[]).length+' callers';` &&
    `  document.getElementById('modal-code').innerHTML=highlightABAP(raw);` &&
    `  document.getElementById('codeModal').classList.add('open');` &&
    `}` &&
    `function closeModal(e){` &&
    `  if(e.target===document.getElementById('codeModal'))` &&
    `    document.getElementById('codeModal').classList.remove('open');` &&
    `}` &&
    `function highlightABAP(src){` &&
    `  var kws=['FORM','ENDFORM','PERFORM','DATA','TYPES','CONSTANTS','IF','ELSE','ELSEIF',` &&
    `    'ENDIF','LOOP','ENDLOOP','READ','APPEND','CLEAR','MODIFY','DELETE','INSERT',` &&
    `    'SELECT','FROM','INTO','WHERE','GROUP','BY','HAVING','ORDER','INNER','JOIN',` &&
    `    'LEFT','OUTER','RETURN','CALL','METHOD','FUNCTION','ENDFUNCTION','MODULE','ENDMODULE',` &&
    `    'TRY','CATCH','ENDTRY','RAISE','EXIT','CHECK','CONTINUE','MOVE','CASE','WHEN','ENDCASE',` &&
    `    'WRITE','MESSAGE','CONCATENATE','SPLIT','FIND','REPLACE','COLLECT','WHILE','ENDWHILE',` &&
    `    'COMMIT','ROLLBACK','IN','AT','END','NEW','CAST','WAIT','SORT','REFRESH',` &&
    `    'TABLE','OF','TYPE','LIKE','REF','VALUE','USING','CHANGING','IMPORTING','EXPORTING',` &&
    `    'TABLES','RAISING','BEGIN','IS','NOT','INITIAL','AND','OR','EQ','NE','LT','GT','LE','GE',` &&
    `    'ABAP_TRUE','ABAP_FALSE','SY','SUBRC','START-OF-SELECTION','END-OF-SELECTION',` &&
    `    'INITIALIZATION','PARAMETERS','SELECT-OPTIONS'];` &&
    `  var kwRe=new RegExp('\\b('+kws.join('|')+')\\b','g');` &&
    `  var lines=src.split('\n'),html='';` &&
    `  for(var i=0;i<lines.length;i++){` &&
    `    var raw=lines[i],trimmed=raw.replace(/^\s+/,'');` &&
    `    if(trimmed.charAt(0)==='*'||trimmed.charAt(0)==='"'){` &&
    `      html+='<span class="ln">'+(i+1)+'</span><span class="cmt">'+escHtml(raw)+'</span>\n';` &&
    `      continue;` &&
    `    }` &&
    `    var parts=raw.split(/(\'[^\']*\')/),out='';` &&
    `    for(var j=0;j<parts.length;j++){` &&
    `      if(j%2===1){` &&
    `        out+="<span class='str'>"+escHtml(parts[j])+"</span>";` &&
    `      }else{` &&
    `        var seg=escHtml(parts[j]);` &&
    `        seg=seg.replace(/\b(\d+)\b/g,"<span class='num'>$1</span>");` &&
    `        seg=seg.replace(kwRe,"<span class='kw'>$1</span>");` &&
    `        out+=seg;` &&
    `      }` &&
    `    }` &&
    `    html+='<span class="ln">'+(i+1)+'</span>'+out+'\n';` &&
    `  }` &&
    `  return html;` &&
    `}` &&
    `function escHtml(t){` &&
    `  return t.replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')` &&
    `           .replace(/"/g,'&quot;');` &&
    `}` &&
    `function resetInfo(){` &&
    `  currentNode=null;` &&
    `  document.getElementById('info').style.display='none';` &&
    `  nodes.update(nodesData.map(function(n){return{id:n.id,opacity:1};}));` &&
    `  edges.update(edgesData.map(function(e,i){` &&
    `    return{id:i,color:{color:'#90a4ae'},width:1};` &&
    `  }));` &&
    `}` &&
    `function fitNetwork(){network.fit({animation:true});}` &&
    `function changeLayout(){` &&
    `  var h=document.getElementById('layoutSel').value==='hierarchical';` &&
    `  network.setOptions({` &&
    `    layout:{hierarchical:{enabled:h,` &&
    `      direction:document.getElementById('dirSel').value,` &&
    `      sortMethod:'directed',nodeSpacing:140,levelSeparation:100}},` &&
    `    physics:{enabled:!h}` &&
    `  });` &&
    `}` &&
    `function changeDir(){` &&
    `  network.setOptions({layout:{hierarchical:{` &&
    `    direction:document.getElementById('dirSel').value}}});` &&
    `}` &&
    `/* ════ EXPORT ════ */` &&
    `function buildExportData(){` &&
    `  var bt='` && '`' && `';` &&
    `  var roots=[],leaves=[],middles=[],orphans=[];` &&
    `  nodesData.forEach(function(n){` &&
    `    var hasCallee=!!(calleeMap[n.id]&&calleeMap[n.id].length);` &&
    `    var hasCaller=!!(callerMap[n.id]&&callerMap[n.id].length);` &&
    `    if(!hasCallee&&!hasCaller)orphans.push(n.id);` &&
    `    else if(!hasCaller)roots.push(n.id);` &&
    `    else if(!hasCallee)leaves.push(n.id);` &&
    `    else middles.push(n.id);` &&
    `  });` &&
    `  var hints=[];` &&
    `  if(orphans.length){` &&
    `    var oList=orphans.map(function(x){return bt+x+bt;}).join(', ');` &&
    `    hints.push('- **Dead code**: '+oList+' - not called and calls nothing');` &&
    `  }` &&
    `  nodesData.forEach(function(n){` &&
    `    var c=(calleeMap[n.id]||[]).length;` &&
    `    if(c>=6)hints.push('- **God routine**: '+bt+n.id+bt+' calls '+c+' others - consider splitting');` &&
    `  });` &&
    `  nodesData.forEach(function(n){` &&
    `    var c=(callerMap[n.id]||[]).length;` &&
    `    if(c>=4)hints.push('- **High coupling**: '+bt+n.id+bt+' called from '+c+' places - ensure stable interface');` &&
    `  });` &&
    `  Object.keys(srcMap).forEach(function(k){` &&
    `    var lines=srcMap[k].split('\n').filter(function(l){` &&
    `      var t=l.trim();return t&&t.charAt(0)!=='*'&&t.charAt(0)!=='"';` &&
    `    });` &&
    `    if(lines.length<=3)hints.push('- **Trivial wrapper**: '+bt+k+bt+' only ~'+lines.length+' lines - consider inlining');` &&
    `  });` &&
    `  if(!hints.length)hints.push('- No obvious issues detected');` &&
    `  return{roots:roots,leaves:leaves,middles:middles,orphans:orphans,hints:hints,bt:bt};` &&
    `}` &&
    `function exportMD(){` &&
    `  var d=buildExportData();` &&
    `  var bt=d.bt;` &&
    `  var bt3=bt+bt+bt;` &&
    `  var prog=document.querySelector('#header span').textContent;` &&
    `  var L=[];` &&
    `  L.push('# ABAP Program Context: '+prog);` &&
    `  L.push('');` &&
    `  L.push('> **Instructions for Claude**: This file contains the full context of ABAP program '+bt+prog+bt+'.');` &&
    `  L.push('> Includes: call graph, selection screen, global declarations, DB table structures, source code, refactor hints.');` &&
    `  L.push('> Use this context to answer questions accurately about this program.');` &&
    `  L.push('');` &&
    `  /* ── SELECTION SCREEN ── */` &&
    `  if(ctxData.sel_screen&&ctxData.sel_screen.length){` &&
    `    L.push('## Selection Screen');` &&
    `    L.push('');` &&
    `    L.push(bt3+'abap');` &&
    `    ctxData.sel_screen.forEach(function(s){L.push(s.def);});` &&
    `    L.push(bt3);` &&
    `    L.push('');` &&
    `  }` &&
    `  /* ── GLOBAL DECLARATIONS ── */` &&
    `  if(ctxData.globals&&ctxData.globals.length){` &&
    `    L.push('## Global Declarations (DATA / TYPES / CONSTANTS)');` &&
    `    L.push('');` &&
    `    L.push(bt3+'abap');` &&
    `    ctxData.globals.forEach(function(g){L.push(g.def);});` &&
    `    L.push(bt3);` &&
    `    L.push('');` &&
    `  }` &&
    `  /* ── TABLE STRUCTURES ── */` &&
    `  var tabs=Object.keys(ctxData.tables||{});` &&
    `  if(tabs.length){` &&
    `    L.push('## Database Table Structures');` &&
    `    L.push('');` &&
    `    tabs.forEach(function(tab){` &&
    `      L.push('### '+tab);` &&
    `      L.push('| Field | Type | Len | Key | Description |');` &&
    `      L.push('|-------|------|-----|-----|-------------|');` &&
    `      (ctxData.tables[tab]||[]).forEach(function(f){` &&
    `        L.push('| '+f.f+' | '+f.t+' | '+f.l+' | '+(f.k?'KEY':'')+' | '+f.d+' |');` &&
    `      });` &&
    `      L.push('');` &&
    `    });` &&
    `  }` &&
    `  /* ── CALL GRAPH ── */` &&
    `  L.push('## Call Graph');` &&
    `  L.push('');` &&
    `  L.push('Entry points (not called by any other block):');` &&
    `  L.push('');` &&
    `  L.push(bt3);` &&
    `  var visited={};` &&
    `  function dfs(id,depth){` &&
    `    var pad='  '.repeat(depth);` &&
    `    var loop=visited[id]?' (loop)':'';` &&
    `    L.push(pad+(depth?'- ':'')+id+loop);` &&
    `    if(visited[id])return;` &&
    `    visited[id]=1;` &&
    `    (calleeMap[id]||[]).forEach(function(c){dfs(c,depth+1);});` &&
    `  }` &&
    `  if(d.roots.length){d.roots.forEach(function(r){dfs(r,0);L.push('');});}` &&
    `  else{L.push('(No entry point detected)');L.push('');}` &&
    `  if(d.orphans.length){` &&
    `    L.push('[Dead code - not connected]');` &&
    `    d.orphans.forEach(function(o){L.push('  '+o);});` &&
    `    L.push('');` &&
    `  }` &&
    `  L.push(bt3);` &&
    `  L.push('');` &&
    `  /* ── REFACTOR HINTS ── */` &&
    `  L.push('## Refactor Hints');` &&
    `  L.push('');` &&
    `  d.hints.forEach(function(h){L.push(h);});` &&
    `  L.push('');` &&
    `  /* ── SOURCE CODE ── roots→middles→leaves→orphans ── */` &&
    `  L.push('## Source Code');` &&
    `  L.push('');` &&
    `  var order=d.roots.concat(d.middles).concat(d.leaves).concat(d.orphans);` &&
    `  order.forEach(function(id){` &&
    `    L.push('### '+id);` &&
    `    var callers=callerMap[id]||[],callees=calleeMap[id]||[],rel=[];` &&
    `    if(callers.length)rel.push('called by: '+callers.map(function(x){return bt+x+bt;}).join(', '));` &&
    `    if(callees.length)rel.push('calls: '+callees.map(function(x){return bt+x+bt;}).join(', '));` &&
    `    if(!callers.length&&!callees.length)rel.push('orphan - not connected');` &&
    `    L.push('> '+rel.join(' | '));` &&
    `    L.push('');` &&
    `    L.push(bt3+'abap');` &&
    `    L.push(srcMap[id]||'(no source)');` &&
    `    L.push(bt3);` &&
    `    L.push('');` &&
    `  });` &&
    `  downloadFile(prog+'_context.md',L.join('\n'),'text/markdown');` &&
    `}` &&
    `function downloadFile(name,content,mime){` &&
    `  var blob=new Blob([content],{type:mime});` &&
    `  var a=document.createElement('a');` &&
    `  a.href=URL.createObjectURL(blob);` &&
    `  a.download=name;a.click();` &&
    `  URL.revokeObjectURL(a.href);` &&
    `}` &&
    `</script></body></html>`.
ENDFORM.

"======================================================================
" Screen 100
"======================================================================
MODULE status_0100 OUTPUT.
  " STATICS: giữ object references qua các lần redraw
  DATA:
    lo_container TYPE REF TO cl_gui_custom_container,
    lo_viewer    TYPE REF TO cl_gui_html_viewer.
  DATA:
    lv_html   TYPE string,
    lv_url    TYPE char255.

  IF lo_container IS INITIAL.
    CREATE OBJECT lo_container
      EXPORTING container_name = 'MAIN_AREA'.
    CREATE OBJECT lo_viewer
      EXPORTING parent = lo_container.
  ENDIF.

  " Build nodes JSON
  DATA(lv_nodes) = VALUE string( ).
  DATA(lv_edges) = VALUE string( ).
  DATA(lv_comma) = VALUE string( ).
  DATA(lv_src)   = VALUE string( ).
  DATA(lv_ctx)   = VALUE string( ).

  lv_nodes = '['.
  LOOP AT gt_forms INTO DATA(ls_f).
    DATA(lv_n) = ls_f-name.
    CONCATENATE lv_nodes lv_comma
      '{"id":"' lv_n '","label":"' lv_n '"}'
      INTO lv_nodes.
    lv_comma = ','.
  ENDLOOP.
  CONCATENATE lv_nodes ']' INTO lv_nodes.

  " Build edges JSON
  CLEAR lv_comma.
  lv_edges = '['.
  LOOP AT gt_calls INTO DATA(ls_c).
    DATA(lv_fr) = ls_c-caller.
    DATA(lv_to) = ls_c-callee.
    CONCATENATE lv_edges lv_comma
      '{"from":"' lv_fr '","to":"' lv_to '"}'
      INTO lv_edges.
    lv_comma = ','.
  ENDLOOP.
  CONCATENATE lv_edges ']' INTO lv_edges.

  " Build source map
  PERFORM f_build_src_json     CHANGING lv_src.
  " Build context (sel screen + globals + tables)
  PERFORM f_build_context_json CHANGING lv_ctx.

  PERFORM f_build_html
    USING lv_nodes lv_edges lv_src lv_ctx gv_progname
    CHANGING lv_html.

  " Chunk HTML into char255 table for load_data
  DATA: lt_html   TYPE TABLE OF char255,
        lv_chunk  TYPE char255,
        lv_len    TYPE i,
        lv_pos    TYPE i,
        lv_remain TYPE i.

  lv_pos    = 0.
  lv_remain = strlen( lv_html ).
  WHILE lv_remain > 0.
    lv_len = COND #( WHEN lv_remain >= 255 THEN 255 ELSE lv_remain ).
    lv_chunk = lv_html+lv_pos(lv_len).
    APPEND lv_chunk TO lt_html.
    lv_pos    = lv_pos + lv_len.
    lv_remain = lv_remain - lv_len.
  ENDWHILE.

  lo_viewer->load_data(
    IMPORTING assigned_url = lv_url
    CHANGING  data_table   = lt_html ).
  lo_viewer->show_url( url = lv_url ).

  SET PF-STATUS 'STAT100'.
  SET TITLEBAR 'TITLE100'.
ENDMODULE.

MODULE user_command_0100 INPUT.
  CASE sy-ucomm.
    WHEN 'BACK' OR 'EXIT' OR 'CANCEL'.
      LEAVE TO SCREEN 0.
  ENDCASE.
ENDMODULE.