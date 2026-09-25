// The external scanner for Wattle strings.
//
// A run of quotes is scanned whole before it is classified: one quote opens
// an ordinary string, two are the empty string, and three or more open a raw
// string that only a run of the same length closes. A `!` before the run
// makes a buffer. Inside an ordinary string the scanner returns each run of
// characters that holds no quote, backslash or line end, so that a `;` in a
// string is not read as a comment.

#include "tree_sitter/parser.h"

enum TokenType {
  STRING_OPEN,
  BUFFER_OPEN,
  EMPTY_STRING,
  EMPTY_BUFFER,
  RAW_STRING,
  RAW_BUFFER,
  STRING_CONTENT,
  ERROR_SENTINEL,
};

void *tree_sitter_wattle_external_scanner_create(void) { return NULL; }
void tree_sitter_wattle_external_scanner_destroy(void *payload) { (void)payload; }
unsigned tree_sitter_wattle_external_scanner_serialize(void *payload, char *buffer) {
  (void)payload;
  (void)buffer;
  return 0;
}
void tree_sitter_wattle_external_scanner_deserialize(void *payload, const char *buffer, unsigned length) {
  (void)payload;
  (void)buffer;
  (void)length;
}

static bool is_space(int32_t c) {
  return c == ' ' || c == '\t' || c == '\n' || c == '\r' || c == '\v' || c == '\f' || c == ',';
}

static unsigned quote_run(TSLexer *lexer) {
  unsigned n = 0;
  while (lexer->lookahead == '"') {
    lexer->advance(lexer, false);
    n++;
  }
  return n;
}

static bool scan_content(TSLexer *lexer) {
  bool any = false;
  while (lexer->lookahead != 0 && lexer->lookahead != '"' && lexer->lookahead != '\\' &&
         lexer->lookahead != '\n' && lexer->lookahead != '\r') {
    lexer->advance(lexer, false);
    any = true;
  }
  if (!any) return false;
  lexer->result_symbol = STRING_CONTENT;
  return true;
}

bool tree_sitter_wattle_external_scanner_scan(void *payload, TSLexer *lexer, const bool *valid) {
  (void)payload;
  if (valid[ERROR_SENTINEL]) return false;
  if (valid[STRING_CONTENT]) return scan_content(lexer);
  if (!valid[STRING_OPEN]) return false;

  while (is_space(lexer->lookahead)) lexer->advance(lexer, true);

  bool buffer = false;
  if (lexer->lookahead == '!') {
    lexer->advance(lexer, false);
    buffer = true;
  }
  if (lexer->lookahead != '"') return false;

  unsigned open = quote_run(lexer);
  if (open == 1) {
    lexer->result_symbol = buffer ? BUFFER_OPEN : STRING_OPEN;
    return true;
  }
  if (open == 2) {
    lexer->result_symbol = buffer ? EMPTY_BUFFER : EMPTY_STRING;
    return true;
  }

  while (lexer->lookahead != 0) {
    if (lexer->lookahead == '"') {
      if (quote_run(lexer) == open) {
        lexer->result_symbol = buffer ? RAW_BUFFER : RAW_STRING;
        return true;
      }
    } else {
      lexer->advance(lexer, false);
    }
  }
  return false;
}
