#include <stdio.h>
#include <string.h>

#define VERSION "0.0.1"

typedef const char* Str;

int main(int argc, char **argv) {
    if (argc < 3 || argc > 4) {
        fprintf(stderr, "Usage: %s <input-file> <output-file> [debug = false]\n", argv[0]);
        return 1;
    }

    Str filename = argv[1];
    Str targetname = argv[2];
    int debug_enabled = 0;
    if (argc > 3 && (strcmp(argv[3], "true") == 0))
        debug_enabled = 1;
    else if (argc > 3 && (strcmp(argv[3], "false") == 0))
        debug_enabled = 0;

    FILE* finput = fopen(filename, "r");
    if (!finput) {
        fprintf(stderr, "Given file '%s' could not be found.\n", filename);
        perror("fopen");
        return 1;
    }

    FILE* ftarget = fopen(targetname, "w");
    if (!ftarget) {
        fprintf(stderr, "Couldn't open file '%s'.\n", targetname);
        perror("fopen");
        return 1;
    }

    char linebuf[8192];
    int lineno = 1;
    int in_debug_block = 0;

    while (fgets(linebuf, sizeof(linebuf), finput)) {

        if (strstr(linebuf, "__DEBUG_START__")) {
            in_debug_block = 1;
            fputs("\n", ftarget);
            lineno++;
            continue;
        }

        if (strstr(linebuf, "__DEBUG_END__")) {
            in_debug_block = 0;
            fputs("\n", ftarget);
            lineno++;
            continue;
        }

        if (in_debug_block && !debug_enabled) {
            fputs("\n", ftarget);
            lineno++;
            continue;
        }

        char *pos;

        while ((pos = strstr(linebuf, "__LINE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%d\"%s", (int)(pos - linebuf), linebuf, lineno, pos + 8); strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__FILE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%s\"%s", (int)(pos - linebuf), linebuf, filename, pos + 8);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__DEBUG__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s%s%s", (int)(pos - linebuf), linebuf, debug_enabled ? "true" : "false", pos + 9);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__VERSION__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s%s%s", (int)(pos - linebuf), linebuf, VERSION, pos + 11);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        fputs(linebuf, ftarget);
        lineno++;
    }

    fclose(finput);
    fclose(ftarget);
    return 0;
}
