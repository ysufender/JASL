#include <stdio.h>
#include <string.h>

#define VERSION "0.0.1"

int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <input-file> [debug = false]\n", argv[0]);
        return 1;
    }

    const char *filename = argv[1];
    int debug_enabled = 0;
    if (argc > 2 && (strcmp(argv[2], "true") == 0))
        debug_enabled = 1;

    FILE *fp = fopen(filename, "r");
    if (!fp) {
        fprintf(stderr, "Given file %s could not be found.\n", filename);
        perror("fopen");
        return 1;
    }

    char linebuf[8192];
    int lineno = 1;
    int in_debug_block = 0;

    while (fgets(linebuf, sizeof(linebuf), fp)) {

        if (strstr(linebuf, "__DEBUG_START__")) {
            in_debug_block = 1;
            fputs("\n", stdout);
            lineno++;
            continue;
        }

        if (strstr(linebuf, "__DEBUG_END__")) {
            in_debug_block = 0;
            fputs("\n", stdout);
            lineno++;
            continue;
        }

        if (in_debug_block && !debug_enabled) {
            fputs("\n", stdout);
            lineno++;
            continue;
        }

        char *pos;

        while ((pos = strstr(linebuf, "__LINE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%d\"%s",
                     (int)(pos - linebuf), linebuf, lineno, pos + 8);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__FILE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%s\"%s",
                     (int)(pos - linebuf), linebuf, filename, pos + 8);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__DEBUG__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s%s%s",
                     (int)(pos - linebuf), linebuf,
                     debug_enabled ? "true" : "false",
                     pos + 9);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        while ((pos = strstr(linebuf, "__VERSION__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s%s%s",
                     (int)(pos - linebuf), linebuf, VERSION, pos + 11);
            strncpy(linebuf, buf, sizeof(linebuf) - 1);
            linebuf[sizeof(linebuf) - 1] = '\0';
        }

        fputs(linebuf, stdout);
        lineno++;
    }

    fclose(fp);
    return 0;
}
