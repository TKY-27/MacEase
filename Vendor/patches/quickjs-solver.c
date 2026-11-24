#include "quickjs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static JSValue console_log(JSContext *context, JSValueConst receiver,
                           int count, JSValueConst *arguments) {
    (void)receiver;
    for (int index = 0; index < count; index++) {
        size_t length;
        const char *text = JS_ToCStringLen(context, &length, arguments[index]);
        if (!text)
            return JS_EXCEPTION;
        int failed = (index > 0 && fputc(' ', stdout) == EOF);
        if (!failed)
            failed = fwrite(text, 1, length, stdout) != length;
        JS_FreeCString(context, text);
        if (failed)
            return JS_ThrowInternalError(context, "Cannot write solver output");
    }
    if (fputc('\n', stdout) == EOF)
        return JS_ThrowInternalError(context, "Cannot write solver output");
    return JS_UNDEFINED;
}

static JSModuleDef *deny_module(JSContext *context, const char *name, void *opaque) {
    (void)name;
    (void)opaque;
    JS_ThrowReferenceError(context, "Module loading is disabled");
    return NULL;
}

static int report_exception(JSContext *context) {
    JSValue exception = JS_GetException(context);
    const char *message = JS_ToCString(context, exception);
    fprintf(stderr, "%s\n", message ? message : "Cannot describe JavaScript exception");
    JS_FreeCString(context, message);
    JS_FreeValue(context, exception);
    return EXIT_FAILURE;
}

static char *read_script(const char *filename, size_t *length) {
    FILE *source = fopen(filename, "rb");
    if (!source) {
        perror("Cannot open solver script");
        return NULL;
    }
    if (fseek(source, 0, SEEK_END) != 0) {
        perror("Cannot seek solver script");
        fclose(source);
        return NULL;
    }
    long extent = ftell(source);
    if (extent < 0 || fseek(source, 0, SEEK_SET) != 0) {
        perror("Cannot measure solver script");
        fclose(source);
        return NULL;
    }
    *length = (size_t)extent;
    char *script = malloc(*length + 1);
    if (!script) {
        fprintf(stderr, "Cannot allocate solver script\n");
        fclose(source);
        return NULL;
    }
    if (fread(script, 1, *length, source) != *length) {
        fprintf(stderr, "Cannot read solver script\n");
        fclose(source);
        free(script);
        return NULL;
    }
    if (fclose(source) != 0) {
        perror("Cannot close solver script");
        free(script);
        return NULL;
    }
    script[*length] = '\0';
    return script;
}

static int evaluate(JSContext *context, const char *script, size_t length, const char *filename) {
    JSValue global = JS_GetGlobalObject(context);
    JSValue console = JS_NewObject(context);
    if (JS_IsException(console)) {
        JS_FreeValue(context, global);
        return report_exception(context);
    }
    JSValue log = JS_NewCFunction(context, console_log, "log", 1);
    if (JS_IsException(log) || JS_SetPropertyStr(context, console, "log", log) < 0) {
        JS_FreeValue(context, console);
        JS_FreeValue(context, global);
        return report_exception(context);
    }
    int installed = JS_SetPropertyStr(context, global, "console", console);
    JS_FreeValue(context, global);
    if (installed < 0)
        return report_exception(context);
    JSValue result = JS_Eval(context, script, length, filename, JS_EVAL_TYPE_GLOBAL);
    if (JS_IsException(result))
        return report_exception(context);
    JS_FreeValue(context, result);
    JSContext *job_context;
    int pending;
    while ((pending = JS_ExecutePendingJob(JS_GetRuntime(context), &job_context)) > 0) {}
    return pending < 0 ? report_exception(job_context) : EXIT_SUCCESS;
}

int main(int count, char **arguments) {
    if (count == 2 && strcmp(arguments[1], "--version") == 0) {
        puts(JS_GetVersion());
        return EXIT_SUCCESS;
    }
    if (count == 2 && strcmp(arguments[1], "--help") == 0) {
        printf("QuickJS-ng version %s\nMacEase solver-only CLI\nUsage: qjs --script FILE\n", JS_GetVersion());
        return EXIT_SUCCESS;
    }
    if (count != 3 || strcmp(arguments[1], "--script") != 0) {
        fprintf(stderr, "Usage: qjs --script FILE\n");
        return EXIT_FAILURE;
    }
    size_t length;
    char *script = read_script(arguments[2], &length);
    if (!script)
        return EXIT_FAILURE;
    JSRuntime *runtime = JS_NewRuntime();
    if (!runtime) {
        fprintf(stderr, "Cannot create JavaScript runtime\n");
        free(script);
        return EXIT_FAILURE;
    }
    JS_SetModuleLoaderFunc(runtime, NULL, deny_module, NULL);
    JSContext *context = JS_NewContext(runtime);
    int status;
    if (context) {
        status = evaluate(context, script, length, arguments[2]);
        JS_FreeContext(context);
    } else {
        fprintf(stderr, "Cannot create JavaScript context\n");
        status = EXIT_FAILURE;
    }
    JS_FreeRuntime(runtime);
    free(script);
    if (fflush(stdout) != 0) {
        perror("Cannot flush solver output");
        status = EXIT_FAILURE;
    }
    return status;
}
