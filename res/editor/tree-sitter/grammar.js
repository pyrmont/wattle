/// <reference types="tree-sitter-cli/dsl" />
// @ts-check

// The grammar follows the lexical syntax in `notes/LANGUAGE.md`. It accepts
// more than the runtime's parser does: a prefix and its form may be on
// different lines, and a word tag such as `#foo` is a syntax error here as it
// is there. Strings are scanned in `src/scanner.c`, because a raw string is
// closed by a run of quotes as long as the run that opened it.

const SYMBOL_CHAR = /[A-Za-z0-9!$%&*+\-./:<=>?@^_\u{80}-\u{10FFFF}]/u.source;
const SYMBOL_START = /[A-Za-z!$%&*+\-./<=>?_\u{80}-\u{10FFFF}]/u.source;

module.exports = grammar({
  name: "wattle",

  extras: ($) => [/[\s,]/, $.comment],

  externals: ($) => [
    $._string_open,
    $._buffer_open,
    $._empty_string,
    $._empty_buffer,
    $.raw_string,
    $.raw_buffer,
    $.string_content,
    $._error_sentinel,
  ],

  word: ($) => $.symbol,

  rules: {
    source_file: ($) => seq(optional($.shebang), repeat($._form)),

    shebang: (_) => token(seq("#!", /[^\r\n]*/)),

    comment: (_) => token(seq(";", /[^\r\n]*/)),

    _form: ($) =>
      choice(
        $.call,
        $.vector,
        $.map,
        $.set,
        $.short_fn,
        $.array,
        $.table,
        $.string,
        alias($._empty_string, $.string),
        $.buffer,
        alias($._empty_buffer, $.buffer),
        $.raw_string,
        $.raw_buffer,
        $.number,
        $.keyword,
        $.nil,
        $.true,
        $.false,
        $.symbol,
        $.quote,
        $.quasiquote,
        $.unquote,
        $.splice,
      ),

    call: ($) => seq("(", repeat($._form), ")"),
    vector: ($) => seq("[", repeat($._form), "]"),
    map: ($) => seq("{", repeat($._form), "}"),
    set: ($) => seq("#{", repeat($._form), "}"),
    short_fn: ($) => seq("#(", repeat($._form), ")"),
    array: ($) =>
      choice(
        seq("![", repeat($._form), "]"),
        seq("!(", repeat($._form), ")"),
      ),
    table: ($) => seq("!{", repeat($._form), "}"),

    string: ($) => seq($._string_open, repeat($._string_part), '"'),
    buffer: ($) => seq($._buffer_open, repeat($._string_part), '"'),
    _string_part: ($) => choice($.string_content, $.escape_sequence),
    escape_sequence: (_) =>
      token.immediate(
        seq(
          "\\",
          choice(
            /x[0-9a-fA-F]{2}/,
            /u[0-9a-fA-F]{4}/,
            /U[0-9a-fA-F]{6}/,
            /[0nrtzfvab'?e"\\]/,
          ),
        ),
      ),

    number: (_) =>
      token(prec(1, new RegExp(`[+-]?(\\.[0-9]|[0-9])(${SYMBOL_CHAR})*`, "u"))),
    keyword: (_) => token(new RegExp(`:(${SYMBOL_CHAR})*`, "u")),
    symbol: (_) => new RegExp(`(${SYMBOL_START})(${SYMBOL_CHAR})*`, "u"),
    nil: (_) => "nil",
    true: (_) => "true",
    false: (_) => "false",

    quote: ($) => seq("'", $._form),
    quasiquote: ($) => seq("`", $._form),
    unquote: ($) => seq("~", $._form),
    splice: ($) => seq("|", $._form),
  },
});
