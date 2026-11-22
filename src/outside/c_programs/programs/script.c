// A scripting language in C, the test program of the configuration of Lua:
// a compiler of one pass to the code of a stack machine, with the numbers of
// Lua 5.4 (integers that wrap, floats, floor division, the modulo of Lua),
// strings on the heap, and errors that leave through longjmp, as Lua raises
// them. print writes through lua_writestring of modus_lua_conf.h.
#include "programs.h"
#include "modus_lua_conf.h"

#define SCRIPT_LOCAL_LIMIT 64
#define SCRIPT_CONSTANT_LIMIT 256
#define SCRIPT_STACK_LIMIT 256
#define SCRIPT_NAME_LIMIT 32
#define SCRIPT_CODE_LIMIT 8192

typedef enum Value_Kind {
  VALUE_NIL,
  VALUE_BOOLEAN,
  VALUE_INTEGER,
  VALUE_FLOAT,
  VALUE_STRING,
} Value_Kind;

typedef struct Script_String {
  struct Script_String *next_allocation;
  size_t length;
  char bytes[];
} Script_String;

typedef struct Value {
  Value_Kind kind;
  union {
    int boolean;
    long long integer;
    double number;
    Script_String *string;
  };
} Value;

typedef enum Operation {
  OPERATION_CONSTANT,
  OPERATION_NIL,
  OPERATION_TRUE,
  OPERATION_FALSE,
  OPERATION_LOAD_LOCAL,
  OPERATION_STORE_LOCAL,
  OPERATION_ADD,
  OPERATION_SUBTRACT,
  OPERATION_MULTIPLY,
  OPERATION_DIVIDE,
  OPERATION_FLOOR_DIVIDE,
  OPERATION_MODULO,
  OPERATION_NEGATE,
  OPERATION_NOT,
  OPERATION_EQUAL,
  OPERATION_NOT_EQUAL,
  OPERATION_LESS,
  OPERATION_LESS_EQUAL,
  OPERATION_GREATER,
  OPERATION_GREATER_EQUAL,
  OPERATION_CONCATENATE,
  OPERATION_JUMP,
  OPERATION_JUMP_IF_FALSE,
  OPERATION_JUMP_IF_FALSE_KEEP,
  OPERATION_JUMP_IF_TRUE_KEEP,
  OPERATION_POP,
  OPERATION_PRINT,
  OPERATION_ERROR,
  OPERATION_HALT,
} Operation;

typedef enum Token_Kind {
  TOKEN_END,
  TOKEN_NAME,
  TOKEN_NUMBER,
  TOKEN_STRING,
  TOKEN_SYMBOL,
} Token_Kind;

typedef struct Token {
  Token_Kind kind;
  const char *start;
  size_t length;
  Value value;
} Token;

typedef struct Script {
  const char *source;
  size_t source_count;
  size_t at;
  int line;
  Token token;
  int code[SCRIPT_CODE_LIMIT];
  int code_count;
  Value constants[SCRIPT_CONSTANT_LIMIT];
  int constant_count;
  char local_names[SCRIPT_LOCAL_LIMIT][SCRIPT_NAME_LIMIT];
  int local_count;
  Value locals[SCRIPT_LOCAL_LIMIT];
  Value stack[SCRIPT_STACK_LIMIT];
  int stack_count;
  Script_String *allocations;
  jmp_buf escape;
  Script_Status failure;
} Script;

static _Noreturn void script_fail(Script *script, Script_Status status, const char *message) {
  char line[200];
  snprintf(line, sizeof line, "line %d: %s\n", script->line, message);
  lua_writestringerror("%s", line);
  script->failure = status;
  longjmp(script->escape, 1);
}

// A string of the length, with its terminating zero; the caller writes its bytes.
static Script_String *string_allocate(Script *script, size_t length) {
  if (length > ((size_t)1 << 30))
    script_fail(script, SCRIPT_STATUS_OUT_OF_MEMORY, "string too long");
  Script_String *string = malloc(sizeof(Script_String) + length + 1);
  if (!string)
    script_fail(script, SCRIPT_STATUS_OUT_OF_MEMORY, "not enough memory");
  string->next_allocation = script->allocations;
  script->allocations = string;
  string->length = length;
  string->bytes[length] = 0;
  return string;
}

static Script_String *string_make(Script *script, const char *bytes, size_t length) {
  Script_String *string = string_allocate(script, length);
  memcpy(string->bytes, bytes, length);
  return string;
}

// Two floats are one constant when their bits are equal: 0.0 and -0.0 are two.
static int bits_equal_float(double left, double right) { return memcmp(&left, &right, sizeof left) == 0; }

// ---- The reader of the source ---------------------------------------------------

static int is_name_start(int c) { return isalpha(c) || c == '_'; }

static void next_token(Script *script) {
  for (;;) {
    while (script->at < script->source_count && isspace((unsigned char)script->source[script->at])) {
      if (script->source[script->at] == '\n')
        script->line++;
      script->at++;
    }
    if (script->at + 1 < script->source_count && script->source[script->at] == '-' &&
        script->source[script->at + 1] == '-') {
      while (script->at < script->source_count && script->source[script->at] != '\n')
        script->at++;
      continue;
    }
    break;
  }
  Token *token = &script->token;
  token->start = script->source + script->at;
  token->length = 0;
  if (script->at >= script->source_count) {
    token->kind = TOKEN_END;
    return;
  }
  const char *at = token->start;
  size_t rest = script->source_count - script->at;
  if (is_name_start((unsigned char)*at)) {
    size_t length = 0;
    while (length < rest && (is_name_start((unsigned char)at[length]) || isdigit((unsigned char)at[length])))
      length++;
    token->kind = TOKEN_NAME;
    token->length = length;
  } else if (isdigit((unsigned char)*at) || (*at == '.' && rest > 1 && isdigit((unsigned char)at[1]))) {
    // The number ends where the source of the number ends, so strtod reads a
    // copy with its terminating zero, never the bytes after the source.
    char text[64];
    size_t length = 0;
    while (length < rest && length < sizeof text - 1 &&
           (isalnum((unsigned char)at[length]) || at[length] == '.' ||
            ((at[length] == '+' || at[length] == '-') && length > 0 &&
             (at[length - 1] == 'e' || at[length - 1] == 'E' || at[length - 1] == 'p' || at[length - 1] == 'P'))))
      length++;
    memcpy(text, at, length);
    text[length] = 0;
    char *end;
    int hexadecimal = text[0] == '0' && (text[1] == 'x' || text[1] == 'X');
    int is_float = hexadecimal ? strpbrk(text, ".pP") != 0 : strpbrk(text, ".eE") != 0;
    if (!is_float) {
      errno = 0;
      unsigned long long value = strtoull(text, &end, hexadecimal ? 16 : 10);
      // A hexadecimal integer wraps around, as in Lua; a decimal one past the
      // largest integer is a float.
      if (*end == 0 && errno == 0 && (hexadecimal || value <= (unsigned long long)LLONG_MAX)) {
        token->value.kind = VALUE_INTEGER;
        token->value.integer = (long long)value;
      } else {
        // A decimal integer past the range of an integer is a float, as in Lua.
        is_float = 1;
      }
    }
    if (is_float) {
      double value = strtod(text, &end);
      if (*end != 0)
        script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "malformed number");
      token->value.kind = VALUE_FLOAT;
      token->value.number = value;
    }
    token->kind = TOKEN_NUMBER;
    token->length = length;
  } else if (*at == '"') {
    size_t length = 1;
    while (length < rest && at[length] != '"' && at[length] != '\n')
      length++;
    if (length >= rest || at[length] != '"')
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "unfinished string");
    token->kind = TOKEN_STRING;
    token->value.kind = VALUE_STRING;
    token->value.string = string_make(script, at + 1, length - 1);
    token->length = length + 1;
  } else {
    static const char *const two_byte_symbols[] = {"==", "~=", "<=", ">=", "//", ".."};
    token->kind = TOKEN_SYMBOL;
    token->length = 1;
    for (size_t index = 0; index < sizeof two_byte_symbols / sizeof two_byte_symbols[0]; index++)
      if (rest >= 2 && at[0] == two_byte_symbols[index][0] && at[1] == two_byte_symbols[index][1])
        token->length = 2;
    if (token->length == 1 && !strchr("+-*/%<>=(),", *at))
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "unexpected symbol");
  }
  script->at += token->length;
}

static int token_is(Script *script, const char *text) {
  size_t length = strlen(text);
  return (script->token.kind == TOKEN_NAME || script->token.kind == TOKEN_SYMBOL) && script->token.length == length &&
         memcmp(script->token.start, text, length) == 0;
}

static void expect(Script *script, const char *text) {
  if (!token_is(script, text)) {
    char message[64];
    snprintf(message, sizeof message, "'%s' expected", text);
    script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, message);
  }
  next_token(script);
}

// ---- The compiler ------------------------------------------------------------------

static void emit(Script *script, int word) {
  if (script->code_count >= SCRIPT_CODE_LIMIT)
    script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "program too large");
  script->code[script->code_count++] = word;
}

static int emit_jump(Script *script, Operation operation) {
  emit(script, (int)operation);
  emit(script, 0);
  return script->code_count - 1;
}

static void patch_jump(Script *script, int place) { script->code[place] = script->code_count; }

// A constant that the program already holds is used again, as Lua does. A
// constant is a number or a string; a string of the source is its own.
static int same_constant(Value known, Value value) {
  if (known.kind != value.kind)
    return 0;
  switch (value.kind) {
  case VALUE_INTEGER:
    return known.integer == value.integer;
  case VALUE_FLOAT:
    return bits_equal_float(known.number, value.number);
  case VALUE_STRING:
    return known.string == value.string;
  case VALUE_NIL:
  case VALUE_BOOLEAN:
    break;
  }
  return 0;
}

static void emit_constant(Script *script, Value value) {
  for (int index = 0; index < script->constant_count; index++) {
    if (same_constant(script->constants[index], value)) {
      emit(script, OPERATION_CONSTANT);
      emit(script, index);
      return;
    }
  }
  if (script->constant_count >= SCRIPT_CONSTANT_LIMIT)
    script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "too many constants");
  script->constants[script->constant_count] = value;
  emit(script, OPERATION_CONSTANT);
  emit(script, script->constant_count++);
}

static int local_find(Script *script, const Token *name) {
  for (int index = script->local_count - 1; index >= 0; index--)
    if (strlen(script->local_names[index]) == name->length &&
        memcmp(script->local_names[index], name->start, name->length) == 0)
      return index;
  return -1;
}

static int is_reserved(const Token *token) {
  static const char *const words[] = {"local", "while", "do", "end", "if", "then", "else", "print",
                                      "error", "and", "or", "not", "nil", "true", "false"};
  for (size_t index = 0; index < sizeof words / sizeof words[0]; index++)
    if (strlen(words[index]) == token->length && memcmp(words[index], token->start, token->length) == 0)
      return 1;
  return 0;
}

static void expression(Script *script);

static void primary(Script *script) {
  Token token = script->token;
  if (token.kind == TOKEN_NUMBER || token.kind == TOKEN_STRING) {
    next_token(script);
    emit_constant(script, token.value);
  } else if (token_is(script, "nil")) {
    next_token(script);
    emit(script, OPERATION_NIL);
  } else if (token_is(script, "true")) {
    next_token(script);
    emit(script, OPERATION_TRUE);
  } else if (token_is(script, "false")) {
    next_token(script);
    emit(script, OPERATION_FALSE);
  } else if (token_is(script, "(")) {
    next_token(script);
    expression(script);
    expect(script, ")");
  } else if (token.kind == TOKEN_NAME && !is_reserved(&token)) {
    int index = local_find(script, &token);
    if (index < 0)
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "unknown variable");
    next_token(script);
    emit(script, OPERATION_LOAD_LOCAL);
    emit(script, index);
  } else {
    script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "unexpected token");
  }
}

static void unary(Script *script) {
  if (token_is(script, "-")) {
    next_token(script);
    unary(script);
    emit(script, OPERATION_NEGATE);
  } else if (token_is(script, "not")) {
    next_token(script);
    unary(script);
    emit(script, OPERATION_NOT);
  } else {
    primary(script);
  }
}

static void multiplicative(Script *script) {
  unary(script);
  for (;;) {
    Operation operation;
    if (token_is(script, "*"))
      operation = OPERATION_MULTIPLY;
    else if (token_is(script, "/"))
      operation = OPERATION_DIVIDE;
    else if (token_is(script, "//"))
      operation = OPERATION_FLOOR_DIVIDE;
    else if (token_is(script, "%"))
      operation = OPERATION_MODULO;
    else
      return;
    next_token(script);
    unary(script);
    emit(script, operation);
  }
}

static void additive(Script *script) {
  multiplicative(script);
  for (;;) {
    Operation operation;
    if (token_is(script, "+"))
      operation = OPERATION_ADD;
    else if (token_is(script, "-"))
      operation = OPERATION_SUBTRACT;
    else
      return;
    next_token(script);
    multiplicative(script);
    emit(script, operation);
  }
}

// ".." is right associative, as in Lua.
static void concatenation(Script *script) {
  additive(script);
  if (token_is(script, "..")) {
    next_token(script);
    concatenation(script);
    emit(script, OPERATION_CONCATENATE);
  }
}

static void comparison(Script *script) {
  concatenation(script);
  for (;;) {
    Operation operation;
    if (token_is(script, "=="))
      operation = OPERATION_EQUAL;
    else if (token_is(script, "~="))
      operation = OPERATION_NOT_EQUAL;
    else if (token_is(script, "<"))
      operation = OPERATION_LESS;
    else if (token_is(script, "<="))
      operation = OPERATION_LESS_EQUAL;
    else if (token_is(script, ">"))
      operation = OPERATION_GREATER;
    else if (token_is(script, ">="))
      operation = OPERATION_GREATER_EQUAL;
    else
      return;
    next_token(script);
    concatenation(script);
    emit(script, operation);
  }
}

static void conjunction(Script *script) {
  comparison(script);
  while (token_is(script, "and")) {
    next_token(script);
    int jump = emit_jump(script, OPERATION_JUMP_IF_FALSE_KEEP);
    comparison(script);
    patch_jump(script, jump);
  }
}

static void expression(Script *script) {
  conjunction(script);
  while (token_is(script, "or")) {
    next_token(script);
    int jump = emit_jump(script, OPERATION_JUMP_IF_TRUE_KEEP);
    conjunction(script);
    patch_jump(script, jump);
  }
}

static int block_ends(Script *script) {
  return script->token.kind == TOKEN_END || token_is(script, "end") || token_is(script, "else");
}

static void statement(Script *script);

static void block(Script *script) {
  int locals_before = script->local_count;
  while (!block_ends(script))
    statement(script);
  script->local_count = locals_before;
}

static void statement(Script *script) {
  if (token_is(script, "local")) {
    next_token(script);
    Token name = script->token;
    if (name.kind != TOKEN_NAME || is_reserved(&name) || name.length >= SCRIPT_NAME_LIMIT)
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "name expected");
    next_token(script);
    expect(script, "=");
    expression(script);
    if (script->local_count >= SCRIPT_LOCAL_LIMIT)
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "too many locals");
    memcpy(script->local_names[script->local_count], name.start, name.length);
    script->local_names[script->local_count][name.length] = 0;
    emit(script, OPERATION_STORE_LOCAL);
    emit(script, script->local_count++);
  } else if (token_is(script, "print") || token_is(script, "error")) {
    int is_print = token_is(script, "print");
    next_token(script);
    expect(script, "(");
    int count = 0;
    if (!token_is(script, ")")) {
      expression(script);
      count++;
      while (token_is(script, ",")) {
        next_token(script);
        expression(script);
        count++;
      }
    }
    expect(script, ")");
    if (is_print) {
      emit(script, OPERATION_PRINT);
      emit(script, count);
    } else {
      if (count != 1)
        script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "error takes one value");
      emit(script, OPERATION_ERROR);
    }
  } else if (token_is(script, "while")) {
    next_token(script);
    int start = script->code_count;
    expression(script);
    int exit_jump = emit_jump(script, OPERATION_JUMP_IF_FALSE);
    expect(script, "do");
    block(script);
    expect(script, "end");
    emit(script, OPERATION_JUMP);
    emit(script, start);
    patch_jump(script, exit_jump);
  } else if (token_is(script, "if")) {
    next_token(script);
    expression(script);
    int else_jump = emit_jump(script, OPERATION_JUMP_IF_FALSE);
    expect(script, "then");
    block(script);
    if (token_is(script, "else")) {
      int end_jump = emit_jump(script, OPERATION_JUMP);
      patch_jump(script, else_jump);
      next_token(script);
      block(script);
      patch_jump(script, end_jump);
    } else {
      patch_jump(script, else_jump);
    }
    expect(script, "end");
  } else if (script->token.kind == TOKEN_NAME && !is_reserved(&script->token)) {
    int index = local_find(script, &script->token);
    if (index < 0)
      script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "unknown variable");
    next_token(script);
    expect(script, "=");
    expression(script);
    emit(script, OPERATION_STORE_LOCAL);
    emit(script, index);
  } else {
    script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "statement expected");
  }
}

// ---- The machine ---------------------------------------------------------------------

static void push(Script *script, Value value) {
  if (script->stack_count >= SCRIPT_STACK_LIMIT)
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "stack overflow");
  script->stack[script->stack_count++] = value;
}

static Value pop(Script *script) { return script->stack[--script->stack_count]; }

static int truthy(Value value) {
  return !(value.kind == VALUE_NIL || (value.kind == VALUE_BOOLEAN && !value.boolean));
}

static int is_number(Value value) { return value.kind == VALUE_INTEGER || value.kind == VALUE_FLOAT; }

static double as_float(Value value) { return value.kind == VALUE_INTEGER ? (double)value.integer : value.number; }

static Value integer_value(long long integer) {
  Value value = {VALUE_INTEGER, {0}};
  value.integer = integer;
  return value;
}

static Value float_value(double number) {
  Value value = {VALUE_FLOAT, {0}};
  value.number = number;
  return value;
}

static Value boolean_value(int boolean) {
  Value value = {VALUE_BOOLEAN, {0}};
  value.boolean = boolean != 0;
  return value;
}

// The text of a value, as tostring of Lua 5.4 writes it: "%.14g" for a
// float, with ".0" when the text looks like an integer.
static size_t value_text(Value value, char *text, size_t capacity) {
  int count = 0;
  switch (value.kind) {
  case VALUE_NIL:
    count = snprintf(text, capacity, "nil");
    break;
  case VALUE_BOOLEAN:
    count = snprintf(text, capacity, "%s", value.boolean ? "true" : "false");
    break;
  case VALUE_INTEGER:
    count = snprintf(text, capacity, "%lld", value.integer);
    break;
  case VALUE_FLOAT:
    count = snprintf(text, capacity, "%.14g", value.number);
    if (text[strspn(text, "-0123456789")] == 0) {
      text[count++] = lua_getlocaledecpoint();
      text[count++] = '0';
      text[count] = 0;
    }
    break;
  case VALUE_STRING:
    return 0;
  }
  return (size_t)count;
}

static long long floor_divide_integers(Script *script, long long left, long long right) {
  if (right == 0)
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to perform 'n//0'");
  if (right == -1)
    return (long long)(0ULL - (unsigned long long)left);
  long long quotient = left / right;
  if ((left % right != 0) && ((left < 0) != (right < 0)))
    quotient--;
  return quotient;
}

static long long modulo_integers(Script *script, long long left, long long right) {
  if (right == 0)
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to perform 'n%0'");
  if (right == -1)
    return 0;
  long long remainder = left % right;
  if (remainder != 0 && ((remainder < 0) != (right < 0)))
    remainder += right;
  return remainder;
}

static double modulo_floats(double left, double right) {
  double remainder = fmod(left, right);
  if (remainder != 0 && ((remainder < 0) != (right < 0)))
    remainder += right;
  return remainder;
}

static Value arithmetic(Script *script, Operation operation, Value left, Value right) {
  if (!is_number(left) || !is_number(right))
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to perform arithmetic on a non-number value");
  int integers = left.kind == VALUE_INTEGER && right.kind == VALUE_INTEGER;
  unsigned long long a = (unsigned long long)left.integer;
  unsigned long long b = (unsigned long long)right.integer;
  double x = as_float(left);
  double y = as_float(right);
  switch (operation) {
  case OPERATION_ADD:
    return integers ? integer_value((long long)(a + b)) : float_value(x + y);
  case OPERATION_SUBTRACT:
    return integers ? integer_value((long long)(a - b)) : float_value(x - y);
  case OPERATION_MULTIPLY:
    return integers ? integer_value((long long)(a * b)) : float_value(x * y);
  case OPERATION_DIVIDE:
    return float_value(x / y);
  case OPERATION_FLOOR_DIVIDE:
    return integers ? integer_value(floor_divide_integers(script, left.integer, right.integer)) : float_value(floor(x / y));
  case OPERATION_MODULO:
    return integers ? integer_value(modulo_integers(script, left.integer, right.integer)) : float_value(modulo_floats(x, y));
  default:
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "bad arithmetic");
  }
}

static int values_equal(Value left, Value right) {
  if (is_number(left) && is_number(right)) {
    if (left.kind == VALUE_INTEGER && right.kind == VALUE_INTEGER)
      return left.integer == right.integer;
    return as_float(left) == as_float(right);
  }
  if (left.kind != right.kind)
    return 0;
  switch (left.kind) {
  case VALUE_NIL:
    return 1;
  case VALUE_BOOLEAN:
    return left.boolean == right.boolean;
  case VALUE_STRING:
    return left.string->length == right.string->length &&
           memcmp(left.string->bytes, right.string->bytes, left.string->length) == 0;
  case VALUE_INTEGER:
  case VALUE_FLOAT:
    break;
  }
  return 0;
}

static int compare_less(Script *script, Value left, Value right, int or_equal) {
  if (is_number(left) && is_number(right)) {
    if (left.kind == VALUE_INTEGER && right.kind == VALUE_INTEGER)
      return or_equal ? left.integer <= right.integer : left.integer < right.integer;
    return or_equal ? as_float(left) <= as_float(right) : as_float(left) < as_float(right);
  }
  if (left.kind == VALUE_STRING && right.kind == VALUE_STRING) {
    int order = strcoll(left.string->bytes, right.string->bytes);
    return or_equal ? order <= 0 : order < 0;
  }
  script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to compare two values of different kinds");
}

static Value concatenate(Script *script, Value left, Value right) {
  char left_text[64], right_text[64];
  const char *left_bytes = left_text, *right_bytes = right_text;
  size_t left_length, right_length;
  if (left.kind == VALUE_STRING) {
    left_bytes = left.string->bytes;
    left_length = left.string->length;
  } else if (is_number(left)) {
    left_length = value_text(left, left_text, sizeof left_text);
  } else {
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to concatenate a value that is no string");
  }
  if (right.kind == VALUE_STRING) {
    right_bytes = right.string->bytes;
    right_length = right.string->length;
  } else if (is_number(right)) {
    right_length = value_text(right, right_text, sizeof right_text);
  } else {
    script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to concatenate a value that is no string");
  }
  if (left_length > ((size_t)1 << 30) - right_length)
    script_fail(script, SCRIPT_STATUS_OUT_OF_MEMORY, "string too long");
  // A new string of both parts: no string changes after it is made.
  Script_String *result = string_allocate(script, left_length + right_length);
  memcpy(result->bytes, left_bytes, left_length);
  memcpy(result->bytes + left_length, right_bytes, right_length);
  Value value = {VALUE_STRING, {0}};
  value.string = result;
  return value;
}

static void print_values(Script *script, int count) {
  Value *values = script->stack + script->stack_count - count;
  for (int index = 0; index < count; index++) {
    if (index > 0)
      lua_writestring("\t", 1);
    if (values[index].kind == VALUE_STRING) {
      lua_writestring(values[index].string->bytes, values[index].string->length);
    } else {
      char text[64];
      size_t length = value_text(values[index], text, sizeof text);
      lua_writestring(text, length);
    }
  }
  lua_writeline();
  script->stack_count -= count;
}

static void execute(Script *script) {
  int at = 0;
  for (long step = 0;; step++) {
    if (step >= SCRIPT_STEP_LIMIT)
      script_fail(script, SCRIPT_STATUS_STEP_LIMIT, "step limit reached");
    Operation operation = (Operation)script->code[at++];
    switch (operation) {
    case OPERATION_CONSTANT:
      push(script, script->constants[script->code[at++]]);
      break;
    case OPERATION_NIL: {
      Value value = {VALUE_NIL, {0}};
      push(script, value);
      break;
    }
    case OPERATION_TRUE:
      push(script, boolean_value(1));
      break;
    case OPERATION_FALSE:
      push(script, boolean_value(0));
      break;
    case OPERATION_LOAD_LOCAL:
      push(script, script->locals[script->code[at++]]);
      break;
    case OPERATION_STORE_LOCAL:
      script->locals[script->code[at++]] = pop(script);
      break;
    case OPERATION_ADD:
    case OPERATION_SUBTRACT:
    case OPERATION_MULTIPLY:
    case OPERATION_DIVIDE:
    case OPERATION_FLOOR_DIVIDE:
    case OPERATION_MODULO: {
      Value right = pop(script);
      Value left = pop(script);
      push(script, arithmetic(script, operation, left, right));
      break;
    }
    case OPERATION_NEGATE: {
      Value value = pop(script);
      if (value.kind == VALUE_INTEGER)
        push(script, integer_value((long long)(0ULL - (unsigned long long)value.integer)));
      else if (value.kind == VALUE_FLOAT)
        push(script, float_value(-value.number));
      else
        script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, "attempt to perform arithmetic on a non-number value");
      break;
    }
    case OPERATION_NOT:
      push(script, boolean_value(!truthy(pop(script))));
      break;
    case OPERATION_EQUAL:
    case OPERATION_NOT_EQUAL: {
      Value right = pop(script);
      Value left = pop(script);
      int equal = values_equal(left, right);
      push(script, boolean_value(operation == OPERATION_EQUAL ? equal : !equal));
      break;
    }
    case OPERATION_LESS:
    case OPERATION_LESS_EQUAL:
    case OPERATION_GREATER:
    case OPERATION_GREATER_EQUAL: {
      Value right = pop(script);
      Value left = pop(script);
      int result;
      switch (operation) {
      case OPERATION_LESS:
        result = compare_less(script, left, right, 0);
        break;
      case OPERATION_LESS_EQUAL:
        result = compare_less(script, left, right, 1);
        break;
      case OPERATION_GREATER:
        result = compare_less(script, right, left, 0);
        break;
      default:
        result = compare_less(script, right, left, 1);
        break;
      }
      push(script, boolean_value(result));
      break;
    }
    case OPERATION_CONCATENATE: {
      Value right = pop(script);
      Value left = pop(script);
      push(script, concatenate(script, left, right));
      break;
    }
    case OPERATION_JUMP:
      at = script->code[at];
      break;
    case OPERATION_JUMP_IF_FALSE: {
      int target = script->code[at++];
      if (!truthy(pop(script)))
        at = target;
      break;
    }
    case OPERATION_JUMP_IF_FALSE_KEEP:
    case OPERATION_JUMP_IF_TRUE_KEEP: {
      int target = script->code[at++];
      int value = truthy(script->stack[script->stack_count - 1]);
      if (value == (operation == OPERATION_JUMP_IF_TRUE_KEEP))
        at = target;
      else
        script->stack_count--;
      break;
    }
    case OPERATION_POP:
      script->stack_count--;
      break;
    case OPERATION_PRINT:
      print_values(script, script->code[at++]);
      break;
    case OPERATION_ERROR: {
      Value value = pop(script);
      char text[64];
      const char *message = text;
      if (value.kind == VALUE_STRING)
        message = value.string->bytes;
      else
        value_text(value, text, sizeof text);
      script_fail(script, SCRIPT_STATUS_RUNTIME_ERROR, message);
    }
    case OPERATION_HALT:
      return;
    }
  }
}

Script_Status script_run(const char *source, size_t source_count, char *output, size_t output_capacity,
                         char *diagnostic, size_t diagnostic_capacity, Modus_Heap *heap) {
  if ((!source && source_count > 0) || !heap)
    return SCRIPT_STATUS_BAD_ARGUMENT;
  modus_lua_output_bind(output, output_capacity, diagnostic, diagnostic_capacity);
  Modus_Heap *previous_heap = modus_heap_current();
  modus_heap_use(heap);
  Script *script = malloc(sizeof(Script));
  if (!script) {
    modus_heap_use(previous_heap);
    return SCRIPT_STATUS_OUT_OF_MEMORY;
  }
  memset(script, 0, sizeof *script);
  script->source = source;
  script->source_count = source_count;
  script->line = 1;
  // volatile: the status is read after a longjmp, which keeps no register.
  volatile Script_Status status = SCRIPT_STATUS_DONE;
  if (setjmp(script->escape) == 0) {
    next_token(script);
    while (script->token.kind != TOKEN_END) {
      if (token_is(script, "end") || token_is(script, "else"))
        script_fail(script, SCRIPT_STATUS_SYNTAX_ERROR, "statement expected");
      statement(script);
    }
    emit(script, OPERATION_HALT);
    execute(script);
  } else {
    status = script->failure;
  }
  if (status == SCRIPT_STATUS_DONE && modus_lua_output_overflowed())
    status = SCRIPT_STATUS_OUTPUT_OVERFLOW;
  while (script->allocations) {
    Script_String *next = script->allocations->next_allocation;
    free(script->allocations);
    script->allocations = next;
  }
  free(script);
  modus_heap_use(previous_heap);
  return status;
}
