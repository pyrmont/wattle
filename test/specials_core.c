#include <assert.h>
#include <string.h>
#include <janet.h>
#include "compile.h"
#include "vector.h"

static const JanetSpecial *special(const char *name) {
    const uint8_t *symbol = janet_csymbol(name);
    const JanetSpecial *result = janetc_special(symbol);
    assert(result != NULL);
    return result;
}

static void clear_error(JanetCompiler *compiler) {
    compiler->result.status = JANET_COMPILE_OK;
    compiler->result.error = NULL;
    compiler->recursion_guard = JANET_RECURSION_GUARD;
}

int main(void) {
    JanetCompiler compiler;
    JanetFopts options;
    JanetSlot result;
    Janet arguments[3];
    JanetScope scope;
    Janet *tuple;
    JanetTable *environment;
    Janet output;

    janet_init();
    assert(janetc_special(janet_csymbol("not-a-special")) == NULL);
    memset(&compiler, 0, sizeof(compiler));
    compiler.recursion_guard = JANET_RECURSION_GUARD;
    options = janetc_fopts_default(&compiler);
    arguments[0] = janet_wrap_integer(1);
    arguments[1] = janet_wrap_integer(2);

    result = special("quote")->compile(options, 1, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(result.constant) == 1);

    result = special("quote")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected 1 argument to quote"));
    clear_error(&compiler);

    result = special("splice")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error,
                   "splice can only be used in function parameters and data constructors, it has no effect here"));
    clear_error(&compiler);

    options.flags |= JANET_FOPTS_ACCEPT_SPLICE;
    result = special("splice")->compile(options, 1, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(result.flags & JANET_SLOT_SPLICED);
    assert(janet_unwrap_integer(result.constant) == 1);
    options.flags = 0;

    result = special("unquote")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "cannot use unquote here"));
    clear_error(&compiler);

    result = special("do")->compile(options, 2, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(result.constant) == 2);
    assert(compiler.scope == NULL);

    result = special("do")->compile(options, 0, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.scope == NULL);

    result = special("upscope")->compile(options, 2, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(result.constant) == 2);
    assert(compiler.scope == NULL);

    result = special("break")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error,
                   "break must occur in while loop or closure"));
    clear_error(&compiler);

    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "function");
    result = special("break")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == JOP_RETURN_NIL);
    janetc_popscope(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_WHILE, "while");
    result = special("break")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(janet_v_count(compiler.buffer) == 1);
    assert(compiler.buffer[0] == (0x80 | JOP_JUMP));
    janetc_popscope(&compiler);

    result = special("if")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected 2 or 3 arguments to if"));
    clear_error(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "if-root");
    arguments[0] = janet_wrap_true();
    arguments[1] = janet_wrap_integer(11);
    arguments[2] = janet_wrap_integer(22);
    result = special("if")->compile(options, 3, arguments);
    assert(compiler.result.status == JANET_COMPILE_OK);
    assert(!(result.flags & JANET_SLOT_CONSTANT));
    assert(janet_v_count(compiler.buffer) == 1);
    janetc_popscope(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "if-root");
    {
        const uint8_t *condition_symbol = janet_csymbol("condition");
        JanetSlot condition = janetc_farslot(&compiler);
        janetc_nameslot(&compiler, condition_symbol, condition, JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = janet_wrap_symbol(condition_symbol);
    }
    result = special("if")->compile(options, 3, arguments);
    assert(compiler.result.status == JANET_COMPILE_OK);
    assert(!(result.flags & JANET_SLOT_CONSTANT));
    assert(janet_v_count(compiler.buffer) >= 4);
    assert((compiler.buffer[0] & 0xFF) == JOP_JUMP_IF_NOT);
    assert((compiler.buffer[0] >> 16) != 0);
    janetc_popscope(&compiler);

    result = special("quasiquote")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected 1 argument to quasiquote"));
    clear_error(&compiler);

    arguments[0] = janet_wrap_integer(42);
    result = special("quasiquote")->compile(options, 1, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(result.constant) == 42);

    tuple = janet_tuple_begin(2);
    tuple[0] = janet_csymbolv("unquote");
    tuple[1] = janet_wrap_integer(43);
    arguments[0] = janet_wrap_tuple(janet_tuple_end(tuple));
    result = special("quasiquote")->compile(options, 1, arguments);
    assert(result.flags & JANET_SLOT_CONSTANT);
    assert(janet_unwrap_integer(result.constant) == 43);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "quasiquote-root");
    tuple = janet_tuple_begin(2);
    tuple[0] = janet_wrap_integer(1);
    tuple[1] = janet_wrap_integer(2);
    arguments[0] = janet_wrap_tuple(janet_tuple_end(tuple));
    result = special("quasiquote")->compile(options, 1, arguments);
    assert(!(result.flags & JANET_SLOT_CONSTANT));
    assert(janet_v_count(compiler.buffer) == 4);
    assert((compiler.buffer[3] & 0xFF) == JOP_MAKE_TUPLE);
    janetc_popscope(&compiler);

    result = special("while")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected at least 1 argument to while"));
    clear_error(&compiler);

    janet_v_empty(compiler.buffer);
    arguments[0] = janet_wrap_false();
    result = special("while")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(janet_v_count(compiler.buffer) == 0);
    assert(compiler.scope == NULL);

    arguments[0] = janet_wrap_true();
    result = special("while")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(janet_v_count(compiler.buffer) == 1);
    assert((compiler.buffer[0] & 0xFF) == JOP_JUMP);
    assert(compiler.scope == NULL);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "while-root");
    {
        const uint8_t *condition_symbol = janet_csymbol("while-condition");
        JanetSlot condition = janetc_farslot(&compiler);
        janetc_nameslot(&compiler, condition_symbol, condition, JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = janet_wrap_symbol(condition_symbol);
        tuple = janet_tuple_begin(1);
        tuple[0] = janet_csymbolv("break");
        arguments[1] = janet_wrap_tuple(janet_tuple_end(tuple));
    }
    result = special("while")->compile(options, 2, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(janet_v_count(compiler.buffer) == 3);
    assert((compiler.buffer[0] & 0xFF) == JOP_JUMP_IF_NOT);
    assert((compiler.buffer[0] >> 16) == 3);
    assert((compiler.buffer[1] & 0xFF) == JOP_JUMP);
    assert((compiler.buffer[1] >> 8) == 2);
    assert((compiler.buffer[2] & 0xFF) == JOP_JUMP);
    janetc_popscope(&compiler);

    result = special("set")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected 2 arguments to set"));
    clear_error(&compiler);

    arguments[0] = janet_wrap_integer(1);
    result = special("set")->compile(options, 2, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error,
                   "expected symbol or tuple for l-value to set"));
    clear_error(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "set-root");
    {
        const uint8_t *mutable_symbol = janet_csymbol("mutable");
        JanetSlot mutable_slot = janetc_farslot(&compiler);
        mutable_slot.flags |= JANET_SLOT_MUTABLE;
        janetc_nameslot(&compiler, mutable_symbol, mutable_slot, JANET_DEFFLAG_NO_SHADOWCHECK);
        arguments[0] = janet_wrap_symbol(mutable_symbol);
        arguments[1] = janet_wrap_integer(7);
        result = special("set")->compile(options, 2, arguments);
        assert(compiler.result.status == JANET_COMPILE_OK);
        assert(result.index == mutable_slot.index);
    }
    janetc_popscope(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "set-field-root");
    {
        JanetTable *table = janet_table(1);
        tuple = janet_tuple_begin(2);
        tuple[0] = janet_wrap_table(table);
        tuple[1] = janet_ckeywordv("key");
        arguments[0] = janet_wrap_tuple(janet_tuple_end(tuple));
        arguments[1] = janet_wrap_integer(8);
        result = special("set")->compile(options, 2, arguments);
        assert(compiler.result.status == JANET_COMPILE_OK);
        assert(janet_v_count(compiler.buffer) > 0);
        assert((compiler.buffer[janet_v_count(compiler.buffer) - 1] & 0xFF) == JOP_PUT);
    }
    janetc_popscope(&compiler);

    result = special("var")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected at least 2 arguments to var"));
    clear_error(&compiler);

    result = special("def")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected at least 2 arguments to def"));
    clear_error(&compiler);

    janet_v_empty(compiler.buffer);
    janetc_scope(&scope, &compiler, JANET_SCOPE_FUNCTION, "fn-root");
    result = special("fn")->compile(options, 0, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error,
                   "expected at least 1 argument to function literal"));
    assert(compiler.scope == &scope);
    clear_error(&compiler);

    arguments[0] = janet_wrap_integer(1);
    result = special("fn")->compile(options, 1, arguments);
    assert(janet_checktype(result.constant, JANET_NIL));
    assert(compiler.result.status == JANET_COMPILE_ERROR);
    assert(!strcmp((const char *) compiler.result.error, "expected function parameters"));
    assert(compiler.scope == &scope);
    clear_error(&compiler);

    tuple = janet_tuple_begin(0);
    arguments[0] = janet_wrap_tuple(janet_tuple_end(tuple));
    result = special("fn")->compile(options, 1, arguments);
    assert(compiler.result.status == JANET_COMPILE_OK);
    assert(!(result.flags & JANET_SLOT_CONSTANT));
    assert(janet_v_count(scope.defs) == 1);
    assert(scope.defs[0]->arity == 0);
    assert(scope.defs[0]->min_arity == 0);
    assert(scope.defs[0]->max_arity == 0);
    assert(scope.defs[0]->bytecode_length == 1);
    assert((scope.defs[0]->bytecode[0] & 0xFF) == JOP_RETURN_NIL);
    assert((compiler.buffer[janet_v_count(compiler.buffer) - 1] & 0xFF) == JOP_CLOSURE);
    janetc_popscope(&compiler);

    janet_v_free(compiler.buffer);

    environment = janet_core_env(NULL);
    assert(janet_dostring(environment,
                          "(fn [condition] (while condition (fn [] condition) (break)))",
                          "specials-core-test",
                          &output) == 0);
    assert(janet_checktype(output, JANET_FUNCTION));

    assert(janet_dostring(environment,
                          "(do (var while-result 0) "
                          "((fn [condition] "
                          "   (while condition "
                          "     (fn [] condition) "
                          "     (set while-result 1) "
                          "     (break))) true) "
                          "while-result)",
                          "specials-core-test",
                          &output) == 0);
    assert(janet_checktype(output, JANET_NUMBER));
    assert(janet_unwrap_number(output) == 1);

    assert(janet_dostring(environment,
                          "(do "
                          "  (var [binding-a binding-b & binding-rest] [1 2 3 4]) "
                          "  (set binding-a 5) "
                          "  [binding-a binding-b binding-rest])",
                          "specials-core-test",
                          &output) == 0);
    assert(janet_checktype(output, JANET_TUPLE));
    {
        const Janet *binding_result = janet_unwrap_tuple(output);
        const Janet *binding_rest = janet_unwrap_tuple(binding_result[2]);
        assert(janet_tuple_length(binding_result) == 3);
        assert(janet_unwrap_integer(binding_result[0]) == 5);
        assert(janet_unwrap_integer(binding_result[1]) == 2);
        assert(janet_tuple_length(binding_rest) == 2);
        assert(janet_unwrap_integer(binding_rest[0]) == 3);
        assert(janet_unwrap_integer(binding_rest[1]) == 4);
    }

    assert(janet_dostring(environment,
                          "(do (def {:x binding-x} {:x 9}) binding-x)",
                          "specials-core-test",
                          &output) == 0);
    assert(janet_checktype(output, JANET_NUMBER));
    assert(janet_unwrap_number(output) == 9);

    assert(janet_dostring(environment,
                          "(def binding-with-doc \"binding documentation\" 10)",
                          "specials-core-test",
                          &output) == 0);
    {
        Janet binding = janet_table_get(environment, janet_csymbolv("binding-with-doc"));
        Janet doc = janet_table_get(janet_unwrap_table(binding), janet_ckeywordv("doc"));
        assert(janet_checktype(doc, JANET_STRING));
        assert(!strcmp((const char *) janet_unwrap_string(doc), "binding documentation"));
    }

    assert(janet_dostring(environment,
                          "[ ((fn [[a b]] (+ a b)) [2 3]) "
                          "  ((fn [a &opt b] [a b]) 1) "
                          "  ((fn [a & rest] rest) 1 2 3) "
                          "  ((fn [&named x y] [x y]) :y 2 :x 1) "
                          "  ((fn recur [n] "
                          "     (if (zero? n) 0 (+ 1 (recur (- n 1))))) 3) ]",
                          "specials-core-test",
                          &output) == 0);
    assert(janet_checktype(output, JANET_TUPLE));
    {
        const Janet *function_results = janet_unwrap_tuple(output);
        const Janet *optional_result = janet_unwrap_tuple(function_results[1]);
        const Janet *rest_result = janet_unwrap_tuple(function_results[2]);
        const Janet *named_result = janet_unwrap_tuple(function_results[3]);
        assert(janet_tuple_length(function_results) == 5);
        assert(janet_unwrap_integer(function_results[0]) == 5);
        assert(janet_unwrap_integer(optional_result[0]) == 1);
        assert(janet_checktype(optional_result[1], JANET_NIL));
        assert(janet_tuple_length(rest_result) == 2);
        assert(janet_unwrap_integer(rest_result[0]) == 2);
        assert(janet_unwrap_integer(rest_result[1]) == 3);
        assert(janet_unwrap_integer(named_result[0]) == 1);
        assert(janet_unwrap_integer(named_result[1]) == 2);
        assert(janet_unwrap_integer(function_results[4]) == 3);
    }

    janet_deinit();
    return 0;
}
