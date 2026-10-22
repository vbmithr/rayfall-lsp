/* SPDX-License-Identifier: MIT */
#include <caml/alloc.h>
#include <caml/custom.h>
#include <caml/fail.h>
#include <caml/memory.h>
#include <caml/mlvalues.h>
#include <tree_sitter/api.h>
#include <stdint.h>
#include <stdlib.h>

extern const TSLanguage *tree_sitter_rayfall(void);
typedef struct {
    const char *kind;
    uint32_t start, end;
    int parent, flags;
} RawNode;
typedef struct { TSTree *tree; RawNode *nodes; } Tree;
#define Holder(v) ((Tree *)Data_custom_val(v))
#define Tree_val(v) (Holder(v)->tree)
static void finalize_tree(value v) {
    if (Tree_val(v)) ts_tree_delete(Tree_val(v));
    free(Holder(v)->nodes);
    Tree_val(v) = NULL;
    Holder(v)->nodes = NULL;
}
static struct custom_operations tree_ops = {
    .identifier = "rayfall-lsp.tree.v1",
    .finalize = finalize_tree,
    .compare = custom_compare_default,
    .hash = custom_hash_default,
    .serialize = custom_serialize_default,
    .deserialize = custom_deserialize_default,
    .compare_ext = custom_compare_ext_default,
    .fixed_length = custom_fixed_length_default,
};

CAMLprim value rayfall_parse(value source) {
    CAMLparam1(source);
    CAMLlocal1(handle);
    if (caml_string_length(source) > 4 * 1024 * 1024)
        caml_invalid_argument("Rayfall source exceeds the 4 MiB prototype limit");
    handle = caml_alloc_custom(&tree_ops, sizeof(Tree), 0, 1);
    Tree_val(handle) = NULL;
    Holder(handle)->nodes = NULL;
    TSParser *parser = ts_parser_new();
    if (!parser) caml_raise_out_of_memory();
    if (!ts_parser_set_language(parser, tree_sitter_rayfall())) {
        ts_parser_delete(parser);
        caml_failwith("incompatible Rayfall Tree-sitter grammar ABI");
    }
    TSTree *tree = ts_parser_parse_string(parser, NULL, String_val(source),
                                         (uint32_t)caml_string_length(source));
    ts_parser_delete(parser);
    if (!tree) caml_failwith("Tree-sitter could not parse Rayfall source");
    Tree_val(handle) = tree;
    CAMLreturn(handle);
}

/* Iterative preorder, copying all nodes into OCaml values. No TSNode pointer
 * escapes this call, so callers can release the native tree immediately. */
CAMLprim value rayfall_tree_nodes(value handle) {
    CAMLparam1(handle);
    CAMLlocal3(array, tuple, kind);
    TSTree *tree = Tree_val(handle);
    if (!tree) caml_invalid_argument("released Rayfall parse tree");
    TSTreeCursor cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
    uint32_t count = 0;
    for (;;) {
        if (++count > 250000) {
            ts_tree_cursor_delete(&cursor);
            caml_invalid_argument("Rayfall syntax tree exceeds 250000 nodes");
        }
        if (ts_tree_cursor_goto_first_child(&cursor)) continue;
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) goto counted;
        }
    }
counted:
    ts_tree_cursor_delete(&cursor);
    RawNode *nodes = calloc(count, sizeof(*nodes));
    int *parents = malloc((size_t)count * sizeof(*parents));
    if (!nodes || !parents) {
        free(nodes); free(parents);
        caml_raise_out_of_memory();
    }
    free(Holder(handle)->nodes);
    Holder(handle)->nodes = nodes;
    cursor = ts_tree_cursor_new(ts_tree_root_node(tree));
    uint32_t depth = 0, index = 0;
    for (;;) {
        TSNode node = ts_tree_cursor_current_node(&cursor);
        nodes[index] = (RawNode){
            ts_node_type(node), ts_node_start_byte(node), ts_node_end_byte(node),
            depth ? parents[depth - 1] : -1,
            (ts_node_is_named(node) ? 1 : 0) | (ts_node_is_error(node) ? 2 : 0)
                | (ts_node_is_missing(node) ? 4 : 0)
        };
        parents[depth] = (int)index++;
        if (ts_tree_cursor_goto_first_child(&cursor)) { ++depth; continue; }
        while (!ts_tree_cursor_goto_next_sibling(&cursor)) {
            if (!ts_tree_cursor_goto_parent(&cursor)) goto finished;
            --depth;
        }
    }
finished:
    ts_tree_cursor_delete(&cursor);
    free(parents);
    /* Only the rooted holder owns native resources across OCaml allocations.
     * Its finalizer also covers exceptions and OOM during conversion. */
    array = caml_alloc(count, 0);
    for (uint32_t i = 0; i < count; ++i) Store_field(array, i, Val_unit);
    for (uint32_t i = 0; i < count; ++i) {
        kind = caml_copy_string(nodes[i].kind);
        tuple = caml_alloc_tuple(5);
        Store_field(tuple, 0, kind);
        Store_field(tuple, 1, Val_long(nodes[i].start));
        Store_field(tuple, 2, Val_long(nodes[i].end));
        Store_field(tuple, 3, Val_int(nodes[i].parent));
        Store_field(tuple, 4, Val_int(nodes[i].flags));
        Store_field(array, i, tuple);
    }
    free(Holder(handle)->nodes);
    Holder(handle)->nodes = NULL;
    CAMLreturn(array);
}
CAMLprim value rayfall_tree_release(value handle) {
    CAMLparam1(handle);
    finalize_tree(handle);
    CAMLreturn(Val_unit);
}
