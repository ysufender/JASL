#include <stdio.h>
#include <string.h>

int main(int argc, char **argv) {
    if(argc < 2 || argc > 3) {
        fprintf(stderr, "Usage: %s <input-file> [debug = false]\n", argv[0]);
        return 1;
    }

    const char *filename = argv[1];
    const char *debug = (argc > 2) ? argv[2] : "false";

    FILE *fp = fopen(filename, "r");
    if(!fp) {
        printf("Given file %s could not be found.", filename);
        perror("fopen");
        return 1;
    }

    char linebuf[8192];
    int lineno = 1;

    while(fgets(linebuf, sizeof(linebuf), fp)) {
        char *pos;
        while((pos = strstr(linebuf, "__LINE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%d\"%s", 
                     (int)(pos - linebuf), linebuf, lineno, pos + 8);
            strncpy(linebuf, buf, sizeof(linebuf));
        }

        while((pos = strstr(linebuf, "__FILE__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s\"%s\"%s", 
                     (int)(pos - linebuf), linebuf, filename, pos + 8);
            strncpy(linebuf, buf, sizeof(linebuf));
        }

        while((pos = strstr(linebuf, "__DEBUG__"))) {
            char buf[8192];
            snprintf(buf, sizeof(buf), "%.*s%s%s", 
                     (int)(pos - linebuf), linebuf, debug, pos + 9);
            strncpy(linebuf, buf, sizeof(linebuf));
        }

        fputs(linebuf, stdout);
        lineno++;
    }

    fclose(fp);
    return 0;
}
