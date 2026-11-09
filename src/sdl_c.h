// Translate-c entry point for the SDL3 bindings. Zig 0.17 removed @cImport;
// the build runs this through addTranslateC and exposes it as module "sdl".
#include <SDL3/SDL.h>
