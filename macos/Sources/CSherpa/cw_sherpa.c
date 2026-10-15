#include "cw_sherpa.h"
#include "sherpa-onnx-c-api.h"

#include <dlfcn.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define FN(name) static __typeof__(&name) p_##name
FN(SherpaOnnxCreateOfflineRecognizer);
FN(SherpaOnnxDestroyOfflineRecognizer);
FN(SherpaOnnxCreateOfflineStream);
FN(SherpaOnnxDestroyOfflineStream);
FN(SherpaOnnxAcceptWaveformOffline);
FN(SherpaOnnxDecodeOfflineStream);
FN(SherpaOnnxGetOfflineStreamResult);
FN(SherpaOnnxDestroyOfflineRecognizerResult);

static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;
static int loaded = 0;

int cw_sherpa_load(const char *dylib_path, char *error, int error_len) {
    pthread_mutex_lock(&lock);
    if (loaded) { pthread_mutex_unlock(&lock); return 0; }
    void *lib = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (!lib) {
        snprintf(error, error_len, "%s", dlerror());
        pthread_mutex_unlock(&lock);
        return 1;
    }
#define LOAD(name) \
    p_##name = (__typeof__(&name))dlsym(lib, #name); \
    if (!p_##name) { snprintf(error, error_len, "brak %s", #name); pthread_mutex_unlock(&lock); return 2; }
    LOAD(SherpaOnnxCreateOfflineRecognizer);
    LOAD(SherpaOnnxDestroyOfflineRecognizer);
    LOAD(SherpaOnnxCreateOfflineStream);
    LOAD(SherpaOnnxDestroyOfflineStream);
    LOAD(SherpaOnnxAcceptWaveformOffline);
    LOAD(SherpaOnnxDecodeOfflineStream);
    LOAD(SherpaOnnxGetOfflineStreamResult);
    LOAD(SherpaOnnxDestroyOfflineRecognizerResult);
    loaded = 1;
    pthread_mutex_unlock(&lock);
    return 0;
}

void *cw_parakeet_create(const char *encoder, const char *decoder, const char *joiner,
                         const char *tokens, int32_t threads) {
    if (!loaded) return NULL;
    // Zera = wartości domyślne sherpa (16 kHz, 80 cech, greedy_search).
    SherpaOnnxOfflineRecognizerConfig config;
    memset(&config, 0, sizeof(config));
    config.model_config.transducer.encoder = encoder;
    config.model_config.transducer.decoder = decoder;
    config.model_config.transducer.joiner = joiner;
    config.model_config.tokens = tokens;
    config.model_config.num_threads = threads;
    config.model_config.provider = "cpu";
    config.model_config.model_type = "nemo_transducer";
    config.decoding_method = "greedy_search";
    return (void *)p_SherpaOnnxCreateOfflineRecognizer(&config);
}

char *cw_parakeet_decode(void *recognizer, const float *samples, int32_t count) {
    if (!loaded || !recognizer) return NULL;
    const SherpaOnnxOfflineRecognizer *r = recognizer;
    const SherpaOnnxOfflineStream *stream = p_SherpaOnnxCreateOfflineStream(r);
    if (!stream) return NULL;
    p_SherpaOnnxAcceptWaveformOffline(stream, 16000, samples, count);
    p_SherpaOnnxDecodeOfflineStream(r, stream);
    const SherpaOnnxOfflineRecognizerResult *result = p_SherpaOnnxGetOfflineStreamResult(stream);
    char *text = strdup(result && result->text ? result->text : "");
    if (result) p_SherpaOnnxDestroyOfflineRecognizerResult(result);
    p_SherpaOnnxDestroyOfflineStream(stream);
    return text;
}

void cw_parakeet_destroy(void *recognizer) {
    if (loaded && recognizer) p_SherpaOnnxDestroyOfflineRecognizer(recognizer);
}
