/*
 * Native (no Android framework) KOReader launcher for the Boyue Likebook T65A.
 *
 * This is a plain bionic executable: it does NOT create an Activity, a
 * SurfaceView, or use SurfaceFlinger. It just opens the LuaJIT shared library,
 * chdir()s into the KOReader module, and runs reader.lua. The T65A device
 * backend then drives /dev/fb0 (imx_epdc_fb) and /dev/input/event* directly.
 *
 * Build with platform/t65a/build-native.sh (NDK, armeabi-v7a, API 19).
 * Run as root (see run-native.sh): the framebuffer and evdev nodes are
 * root/input-only, and SurfaceFlinger/zygote must be stopped first.
 */

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

typedef struct lua_State lua_State;

typedef lua_State *(*luaL_newstate_fn)(void);
typedef void       (*luaL_openlibs_fn)(lua_State *);
typedef int        (*luaL_loadfile_fn)(lua_State *, const char *);
typedef int        (*luaL_loadstring_fn)(lua_State *, const char *);
typedef int        (*lua_pcall_fn)(lua_State *, int, int, int);
typedef const char *(*lua_tolstring_fn)(lua_State *, int, size_t *);
typedef void       (*lua_close_fn)(lua_State *);

static void *must_sym(void *handle, const char *name) {
    void *sym = dlsym(handle, name);
    if (!sym) {
        fprintf(stderr, "koreader-t65a: missing LuaJIT symbol %s: %s\n", name, dlerror());
        exit(1);
    }
    return sym;
}

static void report_error(lua_State *L, lua_tolstring_fn tolstring, const char *what) {
    size_t len = 0;
    const char *msg = tolstring(L, -1, &len);
    fprintf(stderr, "koreader-t65a: %s: %.*s\n", what, (int)len, msg ? msg : "(no message)");
}

int main(int argc, char **argv) {
    const char *home = getenv("KO_HOME");
    if (!home || !*home) {
        home = ".";
    }
    if (chdir(home) != 0) {
        perror("koreader-t65a: chdir");
        return 1;
    }

    void *lib = dlopen("libluajit.so", RTLD_NOW | RTLD_GLOBAL);
    if (!lib) {
        fprintf(stderr, "koreader-t65a: dlopen libluajit.so failed: %s\n", dlerror());
        return 1;
    }

    luaL_newstate_fn    luaL_newstate    = (luaL_newstate_fn)    must_sym(lib, "luaL_newstate");
    luaL_openlibs_fn    luaL_openlibs    = (luaL_openlibs_fn)    must_sym(lib, "luaL_openlibs");
    luaL_loadfile_fn    luaL_loadfile    = (luaL_loadfile_fn)    must_sym(lib, "luaL_loadfile");
    luaL_loadstring_fn  luaL_loadstring  = (luaL_loadstring_fn)  must_sym(lib, "luaL_loadstring");
    lua_pcall_fn        lua_pcall        = (lua_pcall_fn)        must_sym(lib, "lua_pcall");
    lua_tolstring_fn    lua_tolstring    = (lua_tolstring_fn)    must_sym(lib, "lua_tolstring");
    lua_close_fn        lua_close        = (lua_close_fn)        must_sym(lib, "lua_close");

    lua_State *L = luaL_newstate();
    if (!L) {
        fprintf(stderr, "koreader-t65a: luaL_newstate failed\n");
        return 1;
    }
    luaL_openlibs(L);

    /* reader.lua does `local ARGV = arg`; the standalone Lua interpreter
     * normally provides `arg`, an embedded state does not. KOReader's
     * Android launcher (llapp_main.lua) sets arg = {file} before running
     * reader.lua; do the same with an empty table. */
    if (luaL_loadstring(L, "arg = {}") != 0 || lua_pcall(L, 0, 0, 0) != 0) {
        report_error(L, lua_tolstring, "cannot initialize arg");
        lua_close(L);
        return 1;
    }

    const char *script = (argc > 1) ? argv[1] : "reader.lua";
    if (luaL_loadfile(L, script) != 0) {
        report_error(L, lua_tolstring, "cannot load reader.lua");
        lua_close(L);
        return 1;
    }
    if (lua_pcall(L, 0, 0, 0) != 0) {
        report_error(L, lua_tolstring, "reader.lua failed");
        lua_close(L);
        return 1;
    }

    lua_close(L);
    return 0;
}
