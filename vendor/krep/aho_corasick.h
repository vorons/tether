/**
 * Aho-Corasick algorithm for multiple pattern search.
 * This header declares the Aho-Corasick trie structure and functions.
 */

#ifndef AHO_CORASICK_H
#define AHO_CORASICK_H

#include <stdbool.h>
#include <stddef.h> // For size_t
#include <stdint.h> // For uint64_t

// Forward declaration for search_params_t instead of including krep.h
struct search_params;
typedef struct search_params search_params_t;

// Forward declaration for match_result_t (needed by aho_corasick_search)
// Use the same struct tag as defined in krep.h
struct match_result_t;
typedef struct match_result_t match_result_t;

// Forward declaration for internal node structure
struct ac_node;

// Forward declaration for Aho-Corasick trie structure
struct ac_trie;
typedef struct ac_trie ac_trie_t;

// Build the Aho-Corasick Trie from search parameters
ac_trie_t *ac_trie_build(const search_params_t *params);

// Free the Aho-Corasick Trie
void ac_trie_free(ac_trie_t *trie);

// Check if the root node of the trie has any outputs (for empty pattern matching)
bool ac_trie_root_has_outputs(const ac_trie_t *trie);

// Aho-Corasick search function declaration
uint64_t aho_corasick_search(const search_params_t *params, const char *text_start, size_t text_len, match_result_t *result);

#endif // AHO_CORASICK_H
