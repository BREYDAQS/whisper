#ifndef CW_SHERPA_H
#define CW_SHERPA_H

// Parakeet w procesie aplikacji przez C API sherpa-onnx (v1.12.23).
//
// Biblioteka nie jest linkowana przy budowaniu — aplikacja pobiera ją dopiero
// przy pierwszym użyciu — więc ładujemy ją `dlopen` i bierzemy funkcje przez
// `dlsym`. Typy i układ struktur pochodzą z dołączonego nagłówka tej samej
// wersji (`sherpa-onnx-c-api.h`).

#include <stdint.h>

/// Ładuje `libsherpa-onnx-c-api.dylib`. 0 = OK; komunikat błędu w `error`.
int cw_sherpa_load(const char *dylib_path, char *error, int error_len);

/// Model NeMo transducer (Parakeet). NULL = nie udało się.
void *cw_parakeet_create(const char *encoder, const char *decoder, const char *joiner,
                         const char *tokens, int32_t threads);

/// Rozpoznaje 16 kHz mono Float32. Wynik (UTF-8) zwolnić przez `free`.
char *cw_parakeet_decode(void *recognizer, const float *samples, int32_t count);

void cw_parakeet_destroy(void *recognizer);

#endif
