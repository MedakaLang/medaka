/* The C half of the programs in this directory: plain C, no knowledge of
 * Medaka's representation.  bindings.mjs is the JS half and must keep the same
 * semantics, function by function. */
#include <string.h>

long long stub_add(long long a, long long b) { return a + b; }
double stub_scale(double x, double y) { return x * y; }
double stub_float_id(double x) { return x; }
long long stub_not(long long b) { return b ? 0 : 1; }
long long stub_char_next(long long cp) { return cp + 1; }
long long stub_char_id(long long cp) { return cp; }

static char echo_buf[256];
const char *stub_echo(const char *s) {
  size_t n = strlen(s);
  memcpy(echo_buf, s, n);
  echo_buf[n] = '!';
  echo_buf[n + 1] = '\0';
  return echo_buf;
}

long long stub_byte_len(const char *s) { return (long long)strlen(s); }

/* Doubles every element in place and returns the sum from before. */
long long stub_double(long long *xs, long long n) {
  long long sum = 0;
  for (long long i = 0; i < n; i++) {
    sum += xs[i];
    xs[i] *= 2;
  }
  return sum;
}

static long long notes;
void stub_note(const char *s) { notes += (long long)strlen(s); }
long long stub_notes_len(void) { return notes; }

double stub_mix(long long i, double f, const char *s) {
  return (double)i + f + (double)strlen(s);
}

/* same_name/ and method_names.mdk */
long long stub_a_helper(long long x) { return x + 100; }
long long stub_b_helper(long long x) { return x + 200; }
long long stub_mul_add(long long a, long long b) { return a * 100 + b; }
long long stub_prime(long long x) { return x + 10; }
