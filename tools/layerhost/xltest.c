// xltest.c — runs xl_translate() on a recorded commit, for working on the translator without a live process.
//
//   xltest <dump dir>/sim-atoms.txt <dump dir>/<n>-in.bin [out.bin]
//
// The atom names come from the app that recorded the commit (LAYERHOST_DUMP, docs/layerhost.md). XLTEST_TRACE=1 prints
// the commands, objects, atoms and CF values read, with input and output offsets.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "xlate.h"
#include "atoms_mac.h"

static uint8_t *ReadFile(const char *path, size_t *len) {
  FILE *f = fopen(path, "rb");
  if (!f) { perror(path); exit(1); }
  fseek(f, 0, SEEK_END); *len = (size_t)ftell(f); fseek(f, 0, SEEK_SET);
  uint8_t *b = malloc(*len + 1);
  if (fread(b, 1, *len, f) != *len) { perror(path); exit(1); }
  fclose(f);
  b[*len] = 0;
  return b;
}

int main(int argc, char **argv) {
  if (argc < 3) { fprintf(stderr, "usage: xltest sim-atoms.txt in.bin [out.bin]\n"); return 2; }
  size_t n;
  char *text = (char *)ReadFile(argv[1], &n);
  static const char *simNames[XL_SIM_ATOMS];
  unsigned a = 1;
  for (char *line = strtok(text, "\n"); line && a < XL_SIM_ATOMS; line = strtok(NULL, "\n")) simNames[a++] = line;
  static XLMaps maps;
  xl_maps_init(&maps, simNames, a, kMacAtomNames, sizeof kMacAtomNames / sizeof *kMacAtomNames);
  if (getenv("XLTEST_TRACE")) xl_trace = stdout;
  uint8_t *in = ReadFile(argv[2], &n);
  char err[256];
  size_t len;
  uint8_t *out = xl_translate(&maps, in, n, &len, err, sizeof err);
  if (!out) { fprintf(stderr, "xltest: %s\n", err); return 1; }
  fprintf(stderr, "xltest: %zu -> %zu bytes\n", n, len);
  if (argc > 3) {
    FILE *f = fopen(argv[3], "wb");
    if (!f || fwrite(out, 1, len, f) != len) { perror(argv[3]); return 1; }
    fclose(f);
  }
  return 0;
}
