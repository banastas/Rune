; SQL, as Sublime 4 scopes it (Packages/SQL). The grammar makes each keyword a node of its own
; (generated: 356 of them), so every keyword is first Sublime's red keyword, then the kinds Sublime
; colors otherwise: logical and comparison words plain, types storage types, CURRENT_TIMESTAMP and
; OVER functions. A table's columns are declared members; columns and tables elsewhere are plain.
; Later patterns win where two capture the same text.
(comment) @comment.line.double-dash.sql
(marginalia) @comment.block.sql

[(keyword_action) (keyword_add) (keyword_admin) (keyword_after) (keyword_all) (keyword_alter)
 (keyword_always) (keyword_analyze) (keyword_and) (keyword_any) (keyword_array) (keyword_as)
 (keyword_asc) (keyword_atomic) (keyword_attribute) (keyword_authorization) (keyword_auto_increment) (keyword_avro)
 (keyword_before) (keyword_begin) (keyword_between) (keyword_bigint) (keyword_bigserial) (keyword_bin_pack)
 (keyword_binary) (keyword_bit) (keyword_boolean) (keyword_box2d) (keyword_box3d) (keyword_brin)
 (keyword_btree) (keyword_by) (keyword_bytea) (keyword_cache) (keyword_cached) (keyword_called)
 (keyword_cascade) (keyword_cascaded) (keyword_case) (keyword_cast) (keyword_change) (keyword_char)
 (keyword_character) (keyword_characteristics) (keyword_check) (keyword_collate) (keyword_column) (keyword_columns)
 (keyword_comment) (keyword_commit) (keyword_committed) (keyword_compression) (keyword_compute) (keyword_concurrently)
 (keyword_conflict) (keyword_connection) (keyword_constraint) (keyword_constraints) (keyword_copy) (keyword_cost)
 (keyword_create) (keyword_cross) (keyword_csv) (keyword_current) (keyword_current_timestamp) (keyword_cycle)
 (keyword_data) (keyword_database) (keyword_date) (keyword_datetime) (keyword_datetime2) (keyword_datetimeoffset)
 (keyword_decimal) (keyword_declare) (keyword_default) (keyword_deferrable) (keyword_deferred) (keyword_definer)
 (keyword_delayed) (keyword_delete) (keyword_delimited) (keyword_delimiter) (keyword_desc) (keyword_distinct)
 (keyword_do) (keyword_double) (keyword_drop) (keyword_duplicate) (keyword_each) (keyword_else)
 (keyword_encoding) (keyword_encrypted) (keyword_end) (keyword_engine) (keyword_enum) (keyword_escape)
 (keyword_escaped) (keyword_except) (keyword_exclude) (keyword_execute) (keyword_exists) (keyword_explain)
 (keyword_extended) (keyword_extension) (keyword_external) (keyword_false) (keyword_fields) (keyword_filter)
 (keyword_first) (keyword_float) (keyword_following) (keyword_follows) (keyword_for) (keyword_force)
 (keyword_force_not_null) (keyword_force_null) (keyword_force_quote) (keyword_foreign) (keyword_format) (keyword_freeze)
 (keyword_from) (keyword_full) (keyword_function) (keyword_generated) (keyword_geography) (keyword_geometry)
 (keyword_gin) (keyword_gist) (keyword_group) (keyword_groups) (keyword_hash) (keyword_having)
 (keyword_header) (keyword_high_priority) (keyword_if) (keyword_ignore) (keyword_image) (keyword_immediate)
 (keyword_immutable) (keyword_in) (keyword_increment) (keyword_incremental) (keyword_index) (keyword_inet)
 (keyword_initially) (keyword_inner) (keyword_inout) (keyword_input) (keyword_insert) (keyword_instead)
 (keyword_int) (keyword_intersect) (keyword_interval) (keyword_into) (keyword_invoker) (keyword_is)
 (keyword_isolation) (keyword_join) (keyword_json) (keyword_jsonb) (keyword_jsonfile) (keyword_key)
 (keyword_language) (keyword_last) (keyword_lateral) (keyword_leakproof) (keyword_left) (keyword_level)
 (keyword_like) (keyword_limit) (keyword_lines) (keyword_local) (keyword_location) (keyword_logged)
 (keyword_low_priority) (keyword_main) (keyword_match) (keyword_matched) (keyword_materialized) (keyword_maxvalue)
 (keyword_mediumint) (keyword_merge) (keyword_metadata) (keyword_minvalue) (keyword_modify) (keyword_money)
 (keyword_name) (keyword_names) (keyword_natural) (keyword_nchar) (keyword_new) (keyword_no)
 (keyword_none) (keyword_noscan) (keyword_not) (keyword_nothing) (keyword_nowait) (keyword_null)
 (keyword_nulls) (keyword_numeric) (keyword_nvarchar) (keyword_object_id) (keyword_of) (keyword_off)
 (keyword_offset) (keyword_oid) (keyword_oids) (keyword_old) (keyword_on) (keyword_only)
 (keyword_optimize) (keyword_option) (keyword_or) (keyword_orc) (keyword_order) (keyword_ordinality)
 (keyword_others) (keyword_out) (keyword_outer) (keyword_over) (keyword_overwrite) (keyword_owned)
 (keyword_owner) (keyword_parallel) (keyword_parquet) (keyword_partition) (keyword_partitioned) (keyword_password)
 (keyword_plain) (keyword_precedes) (keyword_preceding) (keyword_precision) (keyword_primary) (keyword_procedure)
 (keyword_program) (keyword_quote) (keyword_range) (keyword_rcfile) (keyword_read) (keyword_real)
 (keyword_recursive) (keyword_references) (keyword_referencing) (keyword_regclass) (keyword_regnamespace) (keyword_regproc)
 (keyword_regtype) (keyword_rename) (keyword_repeatable) (keyword_replace) (keyword_replication) (keyword_reset)
 (keyword_restart) (keyword_restrict) (keyword_restricted) (keyword_return) (keyword_returning) (keyword_returns)
 (keyword_rewrite) (keyword_right) (keyword_role) (keyword_rollback) (keyword_row) (keyword_rows)
 (keyword_safe) (keyword_schema) (keyword_security) (keyword_select) (keyword_separator) (keyword_sequence)
 (keyword_sequencefile) (keyword_serial) (keyword_serializable) (keyword_session) (keyword_set) (keyword_setof)
 (keyword_show) (keyword_similar) (keyword_smalldatetime) (keyword_smallint) (keyword_smallmoney) (keyword_smallserial)
 (keyword_snapshot) (keyword_some) (keyword_sort) (keyword_spgist) (keyword_stable) (keyword_start)
 (keyword_statement) (keyword_statistics) (keyword_stats) (keyword_stdin) (keyword_storage) (keyword_stored)
 (keyword_strict) (keyword_string) (keyword_support) (keyword_table) (keyword_tables) (keyword_tablespace)
 (keyword_tblproperties) (keyword_temp) (keyword_temporary) (keyword_terminated) (keyword_text) (keyword_textfile)
 (keyword_then) (keyword_ties) (keyword_time) (keyword_timestamp) (keyword_timestamptz) (keyword_tinyint)
 (keyword_to) (keyword_transaction) (keyword_trigger) (keyword_true) (keyword_truncate) (keyword_type)
 (keyword_unbounded) (keyword_uncached) (keyword_uncommitted) (keyword_union) (keyword_unique) (keyword_unload)
 (keyword_unlogged) (keyword_unsafe) (keyword_unsigned) (keyword_until) (keyword_update) (keyword_use)
 (keyword_user) (keyword_using) (keyword_uuid) (keyword_vacuum) (keyword_valid) (keyword_value)
 (keyword_values) (keyword_varbinary) (keyword_varchar) (keyword_variadic) (keyword_varying) (keyword_verbose)
 (keyword_version) (keyword_view) (keyword_virtual) (keyword_volatile) (keyword_wait) (keyword_when)
 (keyword_where) (keyword_window) (keyword_with) (keyword_without) (keyword_write) (keyword_xml)
 (keyword_zerofill) (keyword_zone)] @keyword.other.sql

[(keyword_create) (keyword_table) (keyword_index) (keyword_view) (keyword_drop) (keyword_alter)
 (keyword_database) (keyword_schema) (keyword_trigger) (keyword_function) (keyword_sequence) (keyword_add)
 (keyword_column) (keyword_rename) (keyword_truncate) (keyword_temporary) (keyword_replace) (keyword_materialized)
 (keyword_type) (keyword_extension)] @keyword.other.ddl.sql
[(keyword_select) (keyword_insert) (keyword_into) (keyword_from) (keyword_join) (keyword_left)
 (keyword_right) (keyword_inner) (keyword_outer) (keyword_full) (keyword_cross) (keyword_natural)
 (keyword_where) (keyword_group) (keyword_by) (keyword_order) (keyword_limit) (keyword_offset)
 (keyword_update) (keyword_set) (keyword_delete) (keyword_returning) (keyword_union) (keyword_intersect)
 (keyword_except) (keyword_all) (keyword_distinct) (keyword_with) (keyword_partition) (keyword_recursive)
 (keyword_lateral) (keyword_window) (keyword_using)] @keyword.other.dml.sql
(keyword_values) @keyword.other.dml.II.sql
[(keyword_and) (keyword_or) (keyword_not) (keyword_is) (keyword_in) (keyword_exists)
 (keyword_having) (keyword_between) (keyword_any) (keyword_some)] @keyword.operator.logical.sql
[(keyword_like) (keyword_similar)] @keyword.operator.comparison.sql
(keyword_as) @keyword.operator.assignment.alias.sql
[(keyword_if) (keyword_case) (keyword_when) (keyword_then) (keyword_else) (keyword_end)] @keyword.control.conditional.sql
[(keyword_asc) (keyword_desc) (keyword_nulls) (keyword_last) (keyword_first)] @keyword.other.order.sql
[(keyword_primary) (keyword_key) (keyword_references) (keyword_default) (keyword_unique) (keyword_foreign)
 (keyword_constraint) (keyword_auto_increment) (keyword_cascade) (keyword_restrict)] @storage.modifier.sql
(keyword_null) @constant.language.null.sql
(keyword_true) @constant.language.boolean.true.sql
(keyword_false) @constant.language.boolean.false.sql
[(keyword_current_timestamp)] @support.function.scalar.sql
(keyword_over) @support.function.sql

[(bigint) (binary) (bit) (char) (datetimeoffset) (decimal)
 (double) (enum) (float) (int) (mediumint) (nchar)
 (numeric) (nvarchar) (smallint) (time) (timestamp) (tinyint)
 (varbinary) (varchar) (keyword_bigserial) (keyword_boolean) (keyword_box2d) (keyword_box3d)
 (keyword_bytea) (keyword_date) (keyword_datetime) (keyword_datetime2) (keyword_geography) (keyword_geometry)
 (keyword_image) (keyword_inet) (keyword_json) (keyword_jsonb) (keyword_money) (keyword_name)
 (keyword_oid) (keyword_regclass) (keyword_regnamespace) (keyword_regproc) (keyword_regtype) (keyword_serial)
 (keyword_smalldatetime) (keyword_smallmoney) (keyword_smallserial) (keyword_string) (keyword_text) (keyword_timestamptz)
 (keyword_uuid) (keyword_xml)] @storage.type.sql

; A type's own words (INT, VARCHAR, WITHOUT TIME ZONE), not the catch-all's keyword.
[(keyword_int) (keyword_bigint) (keyword_smallint) (keyword_tinyint) (keyword_mediumint) (keyword_varchar)
 (keyword_char) (keyword_character) (keyword_varying) (keyword_nchar) (keyword_nvarchar) (keyword_decimal)
 (keyword_numeric) (keyword_double) (keyword_precision) (keyword_float) (keyword_real) (keyword_bit)
 (keyword_binary) (keyword_varbinary) (keyword_time) (keyword_timestamp) (keyword_datetimeoffset) (keyword_zone)
 (keyword_without) (keyword_unsigned) (keyword_zerofill)] @storage.type.sql
; What Sublime's SQL doesn't know reads as a column name there: OVER (PARTITION BY …), INTERVAL.
(partition_by (keyword_partition) @only.meta.column-name.sql)
(partition_by (keyword_by) @only.meta.column-name.sql)
(interval) @meta.interval.sql
(interval (keyword_interval) @only.meta.column-name.sql)

(column_definition name: (identifier) @variable.other.member.declaration.sql)
(invocation (object_reference name: (identifier) @support.function.sql))
(all_fields "*" @constant.other.wildcard.asterisk.sql)
((literal) @constant.numeric.value.sql (#match? @constant.numeric.value.sql "^-?[0-9.]"))
((literal) @string.quoted.single.sql (#match? @string.quoted.single.sql "^'"))
(binary_expression (keyword_like) (literal) @meta.string.like.sql)
(binary_expression (not_like) (literal) @meta.string.like.sql)
