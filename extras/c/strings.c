#include "tl_runtime.h"

#include <ctype.h>
#include <limits.h>
#include <stdlib.h>
#include <string.h>

/* The pattern matcher below is adapted from Lua 5.4 lstrlib.c. */
/******************************************************************************
* Copyright (C) 1994-2025 Lua.org, PUC-Rio.
*
* Permission is hereby granted, free of charge, to any person obtaining
* a copy of this software and associated documentation files (the
* "Software"), to deal in the Software without restriction, including
* without limitation the rights to use, copy, modify, merge, publish,
* distribute, sublicense, and/or sell copies of the Software, and to
* permit persons to whom the Software is furnished to do so, subject to
* the following conditions:
*
* The above copyright notice and this permission notice shall be
* included in all copies or substantial portions of the Software.
*
* THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
* EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
* MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT.
* IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY
* CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT,
* TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION WITH THE
* SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
******************************************************************************/

enum { TL_CAPTURES_MAX = 32, CAP_UNFINISHED = -1, CAP_POSITION = -2 };

typedef struct MatchState {
   tl_State *L;
   const char *src_init;
   const char *src_end;
   const char *p_end;
   int matchdepth;
   int level;
   struct {
      const char *init;
      ptrdiff_t len;
   } capture[TL_CAPTURES_MAX];
} MatchState;

static unsigned char as_byte(char ch) { return (unsigned char)ch; }

/* recursive function */
static const char *match (MatchState *ms, const char *s, const char *p);


/* maximum recursion depth for 'match' */
#if !defined(MAXCCALLS)
#define MAXCCALLS   200
#endif


#define L_ESC      '%'
#define SPECIALS   "^$*+?.([%-"


static int check_capture (MatchState *ms, int l) {
  l -= '1';
  if ((l < 0 || l >= ms->level ||
                 ms->capture[l].len == CAP_UNFINISHED))
    tl_fail(ms->L, "invalid capture index %%%d", l + 1);
  return l;
}


static int capture_to_close (MatchState *ms) {
  int level = ms->level;
  for (level--; level>=0; level--)
    if (ms->capture[level].len == CAP_UNFINISHED) return level;
  tl_fail(ms->L, "invalid pattern capture");
}


static const char *classend (MatchState *ms, const char *p) {
  switch (*p++) {
    case L_ESC: {
      if ((p == ms->p_end))
        tl_fail(ms->L, "malformed pattern (ends with '%%')");
      return p+1;
    }
    case '[': {
      if (*p == '^') p++;
      do {  /* look for a ']' */
        if ((p == ms->p_end))
          tl_fail(ms->L, "malformed pattern (missing ']')");
        if (*(p++) == L_ESC && p < ms->p_end)
          p++;  /* skip escapes (e.g. '%]') */
      } while (*p != ']');
      return p+1;
    }
    default: {
      return p;
    }
  }
}


static int match_class (int c, int cl) {
  int res;
  switch (tolower(cl)) {
    case 'a' : res = isalpha(c); break;
    case 'c' : res = iscntrl(c); break;
    case 'd' : res = isdigit(c); break;
    case 'g' : res = isgraph(c); break;
    case 'l' : res = islower(c); break;
    case 'p' : res = ispunct(c); break;
    case 's' : res = isspace(c); break;
    case 'u' : res = isupper(c); break;
    case 'w' : res = isalnum(c); break;
    case 'x' : res = isxdigit(c); break;
    case 'z' : res = (c == 0); break;  /* deprecated option */
    default: return (cl == c);
  }
  return (islower(cl) ? res : !res);
}


static int matchbracketclass (int c, const char *p, const char *ec) {
  int sig = 1;
  if (*(p+1) == '^') {
    sig = 0;
    p++;  /* skip the '^' */
  }
  while (++p < ec) {
    if (*p == L_ESC) {
      p++;
      if (match_class(c, as_byte(*p)))
        return sig;
    }
    else if ((*(p+1) == '-') && (p+2 < ec)) {
      p+=2;
      if (as_byte(*(p-2)) <= c && c <= as_byte(*p))
        return sig;
    }
    else if (as_byte(*p) == c) return sig;
  }
  return !sig;
}


static int singlematch (MatchState *ms, const char *s, const char *p,
                        const char *ep) {
  if (s >= ms->src_end)
    return 0;
  else {
    int c = as_byte(*s);
    switch (*p) {
      case '.': return 1;  /* matches any char */
      case L_ESC: return match_class(c, as_byte(*(p+1)));
      case '[': return matchbracketclass(c, p, ep-1);
      default:  return (as_byte(*p) == c);
    }
  }
}


static const char *matchbalance (MatchState *ms, const char *s,
                                   const char *p) {
  if ((p >= ms->p_end - 1))
    tl_fail(ms->L, "malformed pattern (missing arguments to '%%b')");
  if (*s != *p) return NULL;
  else {
    int b = *p;
    int e = *(p+1);
    int cont = 1;
    while (++s < ms->src_end) {
      if (*s == e) {
        if (--cont == 0) return s+1;
      }
      else if (*s == b) cont++;
    }
  }
  return NULL;  /* string ends out of balance */
}


static const char *max_expand (MatchState *ms, const char *s,
                                 const char *p, const char *ep) {
  ptrdiff_t i = 0;  /* counts maximum expand for item */
  while (singlematch(ms, s + i, p, ep))
    i++;
  /* keeps trying to match with the maximum repetitions */
  while (i>=0) {
    const char *res = match(ms, (s+i), ep+1);
    if (res) return res;
    i--;  /* else didn't match; reduce 1 repetition to try again */
  }
  return NULL;
}


static const char *min_expand (MatchState *ms, const char *s,
                                 const char *p, const char *ep) {
  for (;;) {
    const char *res = match(ms, s, ep+1);
    if (res != NULL)
      return res;
    else if (singlematch(ms, s, p, ep))
      s++;  /* try with one more repetition */
    else return NULL;
  }
}


static const char *start_capture (MatchState *ms, const char *s,
                                    const char *p, int what) {
  const char *res;
  int level = ms->level;
  if (level >= TL_CAPTURES_MAX) tl_fail(ms->L, "too many captures");
  ms->capture[level].init = s;
  ms->capture[level].len = what;
  ms->level = level+1;
  if ((res=match(ms, s, p)) == NULL)  /* match failed? */
    ms->level--;  /* undo capture */
  return res;
}


static const char *end_capture (MatchState *ms, const char *s,
                                  const char *p) {
  int l = capture_to_close(ms);
  const char *res;
  ms->capture[l].len = s - ms->capture[l].init;  /* close capture */
  if ((res = match(ms, s, p)) == NULL)  /* match failed? */
    ms->capture[l].len = CAP_UNFINISHED;  /* undo capture */
  return res;
}


static const char *match_capture (MatchState *ms, const char *s, int l) {
  size_t len;
  l = check_capture(ms, l);
  len = ms->capture[l].len;
  if ((size_t)(ms->src_end-s) >= len &&
      memcmp(ms->capture[l].init, s, len) == 0)
    return s+len;
  else return NULL;
}


static const char *match (MatchState *ms, const char *s, const char *p) {
  if ((ms->matchdepth-- == 0))
    tl_fail(ms->L, "pattern too complex");
  init: /* using goto to optimize tail recursion */
  if (p != ms->p_end) {  /* end of pattern? */
    switch (*p) {
      case '(': {  /* start capture */
        if (*(p + 1) == ')')  /* position capture? */
          s = start_capture(ms, s, p + 2, CAP_POSITION);
        else
          s = start_capture(ms, s, p + 1, CAP_UNFINISHED);
        break;
      }
      case ')': {  /* end capture */
        s = end_capture(ms, s, p + 1);
        break;
      }
      case '$': {
        if ((p + 1) != ms->p_end)  /* is the '$' the last char in pattern? */
          goto dflt;  /* no; go to default */
        s = (s == ms->src_end) ? s : NULL;  /* check end of string */
        break;
      }
      case L_ESC: {  /* escaped sequences not in the format class[*+?-]? */
        switch (*(p + 1)) {
          case 'b': {  /* balanced string? */
            s = matchbalance(ms, s, p + 2);
            if (s != NULL) {
              p += 4; goto init;  /* return match(ms, s, p + 4); */
            }  /* else fail (s == NULL) */
            break;
          }
          case 'f': {  /* frontier? */
            const char *ep; char previous;
            p += 2;
            if ((*p != '['))
              tl_fail(ms->L, "missing '[' after '%%f' in pattern");
            ep = classend(ms, p);  /* points to what is next */
            previous = (s == ms->src_init) ? '\0' : *(s - 1);
            if (!matchbracketclass(as_byte(previous), p, ep - 1) &&
               matchbracketclass(as_byte(*s), p, ep - 1)) {
              p = ep; goto init;  /* return match(ms, s, ep); */
            }
            s = NULL;  /* match failed */
            break;
          }
          case '0': case '1': case '2': case '3':
          case '4': case '5': case '6': case '7':
          case '8': case '9': {  /* capture results (%0-%9)? */
            s = match_capture(ms, s, as_byte(*(p + 1)));
            if (s != NULL) {
              p += 2; goto init;  /* return match(ms, s, p + 2) */
            }
            break;
          }
          default: goto dflt;
        }
        break;
      }
      default: dflt: {  /* pattern class plus optional suffix */
        const char *ep = classend(ms, p);  /* points to optional suffix */
        /* does not match at least once? */
        if (!singlematch(ms, s, p, ep)) {
          if (*ep == '*' || *ep == '?' || *ep == '-') {  /* accept empty? */
            p = ep + 1; goto init;  /* return match(ms, s, ep + 1); */
          }
          else  /* '+' or no suffix */
            s = NULL;  /* fail */
        }
        else {  /* matched once */
          switch (*ep) {  /* handle optional suffix */
            case '?': {  /* optional */
              const char *res;
              if ((res = match(ms, s + 1, ep + 1)) != NULL)
                s = res;
              else {
                p = ep + 1; goto init;  /* else return match(ms, s, ep + 1); */
              }
              break;
            }
            case '+':  /* 1 or more repetitions */
              s++;  /* 1 match already done */
              /* FALLTHROUGH */
            case '*':  /* 0 or more repetitions */
              s = max_expand(ms, s, p, ep);
              break;
            case '-':  /* 0 or more repetitions (minimum) */
              s = min_expand(ms, s, p, ep);
              break;
            default:  /* no suffix */
              s++; p = ep; goto init;  /* return match(ms, s + 1, ep); */
          }
        }
        break;
      }
    }
  }
  ms->matchdepth++;
  return s;
}



static MatchState matcher(tl_State *L, tl_String *source, tl_String *pattern) {
   return (MatchState){
      .L = L, .src_init = source->bytes, .src_end = source->bytes + source->length,
      .p_end = pattern->bytes + pattern->length, .matchdepth = MAXCCALLS,
   };
}

static const char *try_match(MatchState *state, const char *at, const char *pattern) {
   state->level = 0;
   state->matchdepth = MAXCCALLS;
   return match(state, at, pattern);
}

static tl_Value captured(MatchState *state, int i, const char *from, const char *to) {
   if (i < 0 || (i == 0 && state->level == 0))
      return tl_string(state->L, from, (size_t)(to - from));
   if (i >= state->level || state->capture[i].len == CAP_UNFINISHED)
      tl_fail(state->L, "invalid capture index");
   if (state->capture[i].len == CAP_POSITION)
      return tl_numeric((double)(state->capture[i].init - state->src_init) + 1);
   return tl_string(state->L, state->capture[i].init, (size_t)state->capture[i].len);
}

static int push_captures(MatchState *state, const char *from, const char *to, bool whole) {
   int count = state->level > 0 || !whole ? state->level : 1;
   for (int i = 0; i < count; ++i) tl_push(state->L, captured(state, i, from, to));
   return count;
}

static int64_t relative(int64_t pos, size_t size) {
   return pos >= 0 ? pos : (int64_t)size + pos + 1;
}

static const char *plain_find(const char *source, const char *end, tl_String *needle) {
   if (!needle->length) return source;
   while ((size_t)(end - source) >= needle->length) {
      const char *p = memchr(source, needle->bytes[0], (size_t)(end - source) - needle->length + 1);
      if (!p || !memcmp(p, needle->bytes, needle->length)) return p;
      source = p + 1;
   }
   return NULL;
}

static int find_or_match(tl_State *L, bool find) {
   tl_String *source = tl_checkstring(L, 1);
   tl_String *pattern = tl_checkstring(L, 2);
   int64_t pos = tl_isnil(L, 3) ? 1 : relative(tl_checkinteger(L, 3), source->length);
   if (pos < 1) pos = 1;
   if ((uint64_t)pos <= source->length + 1) {
      MatchState state = matcher(L, source, pattern);
      const char *at = source->bytes + pos - 1;
      if (find && (tl_toboolean(L, 4) || !strpbrk(pattern->bytes, SPECIALS))) {
         const char *hit = plain_find(at, state.src_end, pattern);
         if (hit) {
            tl_pushinteger(L, hit - source->bytes + 1);
            tl_pushinteger(L, hit - source->bytes + (ptrdiff_t)pattern->length);
            return 2;
         }
      } else {
         const char *p = pattern->bytes;
         bool anchor = *p == '^';
         if (anchor) ++p;
         do {
            const char *end = try_match(&state, at, p);
            if (end) {
               if (!find) return push_captures(&state, at, end, true);
               tl_pushinteger(L, at - source->bytes + 1);
               tl_pushinteger(L, end - source->bytes);
               return 2 + push_captures(&state, at, end, false);
            }
            if (at == state.src_end) break;
            ++at;
         } while (!anchor);
      }
   }
   tl_pushnil(L);
   return 1;
}

static int string_find(tl_State *L) { return find_or_match(L, true); }
static int string_match(tl_State *L) { return find_or_match(L, false); }

static int gmatch_next(tl_State *L) {
   tl_Value closure = tl_at(L, TL_CAPTURES);
   tl_String *source = tl_rawget(closure, tl_numeric(1)).as.string;
   tl_String *pattern = tl_rawget(closure, tl_numeric(2)).as.string;
   size_t pos = (size_t)tl_rawget(closure, tl_numeric(3)).as.number;
   double previous = tl_rawget(closure, tl_numeric(4)).as.number;
   MatchState state = matcher(L, source, pattern);
   for (; pos <= source->length; ++pos) {
      const char *at = source->bytes + pos;
      const char *end = try_match(&state, at, pattern->bytes);
      if (!end || (double)(end - source->bytes) == previous) continue;
      tl_Value offset = tl_numeric((double)(end - source->bytes));
      tl_rawput(L, closure, tl_numeric(3), offset);
      tl_rawput(L, closure, tl_numeric(4), offset);
      return push_captures(&state, at, end, true);
   }
   return 0;
}

static int string_gmatch(tl_State *L) {
   tl_String *source = tl_checkstring(L, 1);
   tl_String *pattern = tl_checkstring(L, 2);
   int64_t pos = tl_isnil(L, 3) ? 1 : relative(tl_checkinteger(L, 3), source->length);
   tl_Value closure = tl_table(L, 4, 0);
   tl_rawput(L, closure, tl_numeric(1), tl_object(&source->header));
   tl_rawput(L, closure, tl_numeric(2), tl_object(&pattern->header));
   tl_rawput(L, closure, tl_numeric(3), tl_numeric(pos < 1 ? 0 : (double)(pos - 1)));
   tl_rawput(L, closure, tl_numeric(4), tl_numeric(-1));
   tl_push(L, closure);
   tl_pushcclosure(L, gmatch_next, 1);
   return 1;
}

static void append_replacement(tl_State *L, tl_Buffer *out, MatchState *state, tl_Value repl,
                               const char *from, const char *to) {
   tl_String *format = tl_asstring(L, repl);
   if (format) {
      for (size_t i = 0; i < format->length; ++i) {
         char ch = format->bytes[i];
         if (ch != '%') {
            tl_buffer_byte(L, out, ch);
            continue;
         }
         ch = format->bytes[++i];
         if (ch == '%') tl_buffer_byte(L, out, ch);
         else if (ch >= '0' && ch <= '9') {
            tl_String *capture = tl_asstring(L, captured(state, ch - '1', from, to));
            tl_buffer_add(L, out, capture->bytes, capture->length);
         } else {
            tl_fail(L, "invalid use of '%%' in replacement string");
         }
      }
   } else {
      tl_Value result;
      if (repl.type == TL_FUNCTION) {
         tl_push(L, repl);
         int n = push_captures(state, from, to, true);
         tl_call(L, n, 1);
         result = tl_at(L, -1);
         tl_pop(L, 1);
      } else if (repl.type == TL_TABLE) {
         result = tl_getkey(L, repl, captured(state, 0, from, to));
      } else {
         tl_fail(L, "invalid replacement value");
      }
      if (!tl_truth(result)) {
         tl_buffer_add(L, out, from, (size_t)(to - from));
      } else {
         tl_String *string = tl_asstring(L, result);
         if (!string) tl_fail(L, "invalid replacement value (a %s)", tl_typename(result));
         tl_buffer_add(L, out, string->bytes, string->length);
      }
   }
}

static int string_gsub(tl_State *L) {
   tl_String *source = tl_checkstring(L, 1);
   tl_String *pattern = tl_checkstring(L, 2);
   tl_Value replacement = tl_at(L, 3);
   int64_t limit = tl_isnil(L, 4) ? (int64_t)source->length + 1 : tl_checkinteger(L, 4);
   /* String arguments can be converted from numbers. Root their converted values. */
   tl_push(L, tl_object(&source->header));
   tl_push(L, tl_object(&pattern->header));
   MatchState state = matcher(L, source, pattern);
   const char *p = pattern->bytes;
   bool anchor = *p == '^';
   if (anchor) ++p;
   tl_Buffer out = {0};
   const char *at = source->bytes;
   const char *previous = NULL;
   int64_t count = 0;
   while (count < limit) {
      const char *end = try_match(&state, at, p);
      if (end && end != previous) {
         ++count;
         append_replacement(L, &out, &state, replacement, at, end);
         at = end;
         previous = end;
      } else if (at < state.src_end) {
         tl_buffer_byte(L, &out, *at++);
      } else {
         break;
      }
      if (anchor) break;
   }
   tl_buffer_add(L, &out, at, (size_t)(state.src_end - at));
   tl_buffer_push(L, &out);
   tl_pushinteger(L, count);
   return 2;
}

static int string_sub(tl_State *L) {
   tl_String *s = tl_checkstring(L, 1);
   int64_t start = relative(tl_checkinteger(L, 2), s->length);
   int64_t end = tl_isnil(L, 3) ? (int64_t)s->length : relative(tl_checkinteger(L, 3), s->length);
   if (start < 1) start = 1;
   if (end > (int64_t)s->length) end = (int64_t)s->length;
   if (start > end) tl_pushlstring(L, "", 0);
   else tl_pushlstring(L, s->bytes + start - 1, (size_t)(end - start + 1));
   return 1;
}

static int string_byte(tl_State *L) {
   tl_String *s = tl_checkstring(L, 1);
   int64_t start = tl_isnil(L, 2) ? 1 : relative(tl_checkinteger(L, 2), s->length);
   int64_t end = tl_isnil(L, 3) ? start : relative(tl_checkinteger(L, 3), s->length);
   if (start < 1) start = 1;
   if (end > (int64_t)s->length) end = (int64_t)s->length;
   if (start > end) return 0;
   int count = (int)(end - start + 1);
   tl_reserve(L, count);
   for (int i = 0; i < count; ++i) tl_pushinteger(L, as_byte(s->bytes[start - 1 + i]));
   return count;
}

static int string_char(tl_State *L) {
   int count = tl_gettop(L);
   tl_Buffer out = {0};
   for (int i = 1; i <= count; ++i) {
      int64_t value = tl_checkinteger(L, i);
      if (value < 0 || value > 255) {
         free(out.data);
         tl_fail(L, "value out of range in string.char");
      }
      tl_buffer_byte(L, &out, (char)value);
   }
   tl_buffer_push(L, &out);
   return 1;
}

static int string_len(tl_State *L) {
   tl_pushnumber(L, (double)tl_checkstring(L, 1)->length);
   return 1;
}

static int string_rep(tl_State *L) {
   tl_String *s = tl_checkstring(L, 1);
   int64_t n = tl_checkinteger(L, 2);
   tl_String *sep = tl_isnil(L, 3) ? NULL : tl_checkstring(L, 3);
   tl_Buffer out = {0};
   if (s->length || (sep && sep->length)) {
      for (int64_t i = 0; i < n; ++i) {
         if (i && sep) tl_buffer_add(L, &out, sep->bytes, sep->length);
         tl_buffer_add(L, &out, s->bytes, s->length);
      }
   }
   tl_buffer_push(L, &out);
   return 1;
}

static int string_case(tl_State *L, bool upper) {
   tl_String *s = tl_checkstring(L, 1);
   tl_Buffer out = {0};
   for (size_t i = 0; i < s->length; ++i) {
      int ch = as_byte(s->bytes[i]);
      tl_buffer_byte(L, &out, (char)(upper ? toupper(ch) : tolower(ch)));
   }
   tl_buffer_push(L, &out);
   return 1;
}

static int string_lower(tl_State *L) { return string_case(L, false); }
static int string_upper(tl_State *L) { return string_case(L, true); }

static int string_reverse(tl_State *L) {
   tl_String *s = tl_checkstring(L, 1);
   tl_Buffer out = {0};
   for (size_t i = s->length; i > 0; --i) tl_buffer_byte(L, &out, s->bytes[i - 1]);
   tl_buffer_push(L, &out);
   return 1;
}

static void quote(tl_State *L, tl_Buffer *out, tl_String *s) {
   tl_buffer_byte(L, out, '"');
   for (size_t i = 0; i < s->length; ++i) {
      unsigned char ch = as_byte(s->bytes[i]);
      if (ch == '"' || ch == '\\' || ch == '\n') {
         tl_buffer_byte(L, out, '\\');
         tl_buffer_byte(L, out, (char)ch);
      } else if (ch < 32 || ch == 127) {
         char escape[5];
         bool digit = i + 1 < s->length && isdigit(as_byte(s->bytes[i + 1]));
         int count = snprintf(escape, sizeof escape, digit ? "\\%03u" : "\\%u", (unsigned)ch);
         tl_buffer_add(L, out, escape, (size_t)count);
      } else {
         tl_buffer_byte(L, out, (char)ch);
      }
   }
   tl_buffer_byte(L, out, '"');
}

static int string_format(tl_State *L) {
   tl_String *format = tl_checkstring(L, 1);
   /* A formatter may call the global tostring, which can collect. */
   int args = tl_gettop(L);
   tl_push(L, tl_object(&format->header));
   tl_Buffer out = {0};
   int next = 2;
   for (size_t i = 0; i < format->length; ++i) {
      char ch = format->bytes[i];
      if (ch != '%') {
         tl_buffer_byte(L, &out, ch);
         continue;
      }
      if (format->bytes[i + 1] == '%') {
         tl_buffer_byte(L, &out, '%');
         ++i;
         continue;
      }
      size_t start = i++;
      bool left = false;
      while (format->bytes[i] && strchr("-+ #0", format->bytes[i])) {
         if (format->bytes[i] == '-') left = true;
         ++i;
      }
      size_t width = 0;
      while (isdigit(as_byte(format->bytes[i]))) {
         if (width > 10000) tl_fail(L, "format width too large");
         width = width * 10 + (unsigned)(format->bytes[i++] - '0');
      }
      size_t precision = SIZE_MAX;
      if (format->bytes[i] == '.') {
         precision = 0;
         ++i;
         while (isdigit(as_byte(format->bytes[i]))) {
            if (precision > 10000) tl_fail(L, "format precision too large");
            precision = precision * 10 + (unsigned)(format->bytes[i++] - '0');
         }
      }
      char code = format->bytes[i];
      if (!code || i - start > 30 || next > args) tl_fail(L, "invalid format or missing argument");
      const int index = next++;
      if (code == 's' || code == 'q') {
         tl_String *str = tl_asstring(L, tl_at(L, index));
         if (!str && code == 's') {
            tl_getglobal(L, "tostring");
            tl_pushvalue(L, index);
            tl_call(L, 1, 1);
            str = tl_checkstring(L, -1);
            tl_pop(L, 1);
         }
         if (!str) tl_fail(L, "string expected for string.format");
         if (code == 'q') {
            quote(L, &out, str);
         } else {
            size_t count = str->length < precision ? str->length : precision;
            size_t padding = width > count ? width - count : 0;
            if (!left) for (size_t j = 0; j < padding; ++j) tl_buffer_byte(L, &out, ' ');
            tl_buffer_add(L, &out, str->bytes, count);
            if (left) for (size_t j = 0; j < padding; ++j) tl_buffer_byte(L, &out, ' ');
         }
         continue;
      }

      char spec[36];
      size_t length = i - start;
      memcpy(spec, format->bytes + start, length);
      if (strchr("diouxX", code)) {
         spec[length++] = 'l';
         spec[length++] = 'l';
      }
      spec[length++] = code;
      spec[length] = '\0';
      int written;
      char fixed[256];
      double number = tl_checknumber(L, index);
      bool integral = strchr("diouxXc", code) != NULL;
      uint64_t integer = 0;
      if (integral) {
         if (number >= -0x1p63 && number < 0x1p63) integer = (uint64_t)(int64_t)number;
         else if (number >= 0 && number < 0x1p64) integer = (uint64_t)number;
         else tl_fail(L, "integer out of range in string.format");
      }
#define FORMAT_TO(buffer, capacity) \
      (code == 'd' || code == 'i' ? snprintf(buffer, capacity, spec, (long long)integer) : \
       code == 'c' ? snprintf(buffer, capacity, spec, (int)integer) : \
       integral ? snprintf(buffer, capacity, spec, (unsigned long long)integer) : \
       snprintf(buffer, capacity, spec, number))
      if (!integral && !strchr("aAeEfFgG", code)) tl_fail(L, "invalid option '%%%c' in format", code);
      written = FORMAT_TO(fixed, sizeof fixed);
      if (written < 0) tl_fail(L, "failed to format value");
      if ((size_t)written < sizeof fixed) {
         tl_buffer_add(L, &out, fixed, (size_t)written);
      } else {
         char *big = tl_resize(L, NULL, (size_t)written + 1);
         FORMAT_TO(big, (size_t)written + 1);
         tl_buffer_add(L, &out, big, (size_t)written);
         free(big);
      }
#undef FORMAT_TO
   }
   tl_buffer_push(L, &out);
   return 1;
}

static int utf8_char(tl_State *L) {
   int count = tl_gettop(L);
   tl_Buffer out = {0};
   for (int i = 1; i <= count; ++i) {
      int64_t number = tl_checkinteger(L, i);
      if (number < 0 || number > 0x10ffff) {
         free(out.data);
         tl_fail(L, "UTF-8 code point out of range");
      }
      unsigned cp = (unsigned)number;
      if (cp < 0x80) {
         tl_buffer_byte(L, &out, (char)cp);
      } else {
         int more = cp < 0x800 ? 1 : cp < 0x10000 ? 2 : 3;
         unsigned first = more == 1 ? 0xc0 : more == 2 ? 0xe0 : 0xf0;
         tl_buffer_byte(L, &out, (char)(first | (cp >> (6 * more))));
         for (int j = more - 1; j >= 0; --j)
            tl_buffer_byte(L, &out, (char)(0x80 | ((cp >> (6 * j)) & 63)));
      }
   }
   tl_buffer_push(L, &out);
   return 1;
}

static const tl_Library strings[] = {
   { "find", string_find }, { "match", string_match }, { "gmatch", string_gmatch }, { "gsub", string_gsub },
   { "sub", string_sub }, { "rep", string_rep }, { "format", string_format },
   { "byte", string_byte }, { "char", string_char }, { "len", string_len },
   { "lower", string_lower }, { "upper", string_upper }, { "reverse", string_reverse }, { NULL, NULL }
};

static const tl_Library utf8[] = { { "char", utf8_char }, { NULL, NULL } };

void tl_openstrings(tl_State *L) {
   L->string_lib = tl_table(L, 0, 16);
   tl_library(L, L->string_lib, strings);
   tl_putfield(L, L->globals, "string", L->string_lib);

   tl_Value ut = tl_table(L, 0, 2);
   tl_library(L, ut, utf8);
   tl_putfield(L, ut, "charpattern", tl_cstring(L, "[%z\1-\127\194-\244][\128-\191]*"));
   tl_putfield(L, L->globals, "utf8", ut);
}
