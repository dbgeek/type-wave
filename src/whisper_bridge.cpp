#include "whisper_bridge.h"

#include "whisper.h"

#include <atomic>
#include <cstdio>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <unistd.h>

struct tw_whisper_runtime {
    whisper_context * context = nullptr;
    std::atomic_bool cancelled{false};
    std::atomic_bool metal_library_loaded{false};
    std::atomic_bool metal_backend_selected{false};
    std::string transcript;
};

struct fd_loader {
    int fd;
    off_t offset = 0;
    off_t size;
};

static size_t loader_read(void * user_data, void * output, size_t read_size) {
    auto * loader = static_cast<fd_loader *>(user_data);
    const ssize_t count = pread(loader->fd, output, read_size, loader->offset);
    if (count <= 0) return 0;
    loader->offset += count;
    return static_cast<size_t>(count);
}

static bool loader_eof(void * user_data) {
    auto * loader = static_cast<fd_loader *>(user_data);
    return loader->offset >= loader->size;
}

static void loader_close(void *) {}

static void runtime_log(enum ggml_log_level, const char * text, void * user_data) {
    auto * runtime = static_cast<tw_whisper_runtime *>(user_data);
    if (std::strstr(text, "ggml_metal_library_init: loaded") != nullptr) {
        runtime->metal_library_loaded.store(true, std::memory_order_release);
    }
    if (std::strstr(text, "whisper_backend_init_gpu: using ") != nullptr &&
        std::strstr(text, " backend") != nullptr) {
        runtime->metal_backend_selected.store(true, std::memory_order_release);
    }
    if (std::strstr(text, "whisper_backend_init_gpu: failed to initialize ") != nullptr) {
        runtime->metal_backend_selected.store(false, std::memory_order_release);
    }
    std::fputs(text, stderr);
}

static bool should_abort(void * user_data) {
    auto * runtime = static_cast<tw_whisper_runtime *>(user_data);
    return runtime->cancelled.load(std::memory_order_acquire);
}

static whisper_full_params parameters(tw_whisper_runtime * runtime, const char * language, const char * prompt) {
    whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.n_threads = 4;
    params.language = language;
    // Custom-vocabulary biasing (docs/vocab-biasing-spec.md §5): the borrowed glossary lives
    // across the synchronous whisper_full below, so no C++ heap is taken on the inference path.
    // An empty/absent prompt leaves initial_prompt null — byte-identical to the pre-biasing no-op.
    params.initial_prompt = (prompt != nullptr && prompt[0] != '\0') ? prompt : nullptr;
    params.detect_language = false;
    params.no_context = true;
    params.no_timestamps = true;
    params.single_segment = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.greedy.best_of = 1;
    params.abort_callback = should_abort;
    params.abort_callback_user_data = runtime;
    return params;
}

extern "C" tw_whisper_runtime * tw_whisper_create(int model_fd) {
    struct stat stat{};
    if (fstat(model_fd, &stat) != 0 || stat.st_size <= 0) return nullptr;
    fd_loader source{model_fd, 0, stat.st_size};
    whisper_model_loader loader{&source, loader_read, loader_eof, loader_close};
    whisper_context_params params = whisper_context_default_params();
    params.use_gpu = true;
    params.flash_attn = true;
    auto * runtime = new tw_whisper_runtime();
    whisper_log_set(runtime_log, runtime);
    runtime->context = whisper_init_with_params(&loader, params);
    if (runtime->context == nullptr) {
        delete runtime;
        return nullptr;
    }
    return runtime;
}

extern "C" void tw_whisper_destroy(tw_whisper_runtime * runtime) {
    if (runtime == nullptr) return;
    whisper_free(runtime->context);
    delete runtime;
}

extern "C" bool tw_whisper_warm(tw_whisper_runtime * runtime) {
    // Context creation loads the model and initializes the embedded Metal library (the
    // first-use preparation measured by the accepted base-M1 prototype). Validate that
    // the loaded vocabulary is usable without running a padded decoding workload.
    return runtime->metal_library_loaded.load(std::memory_order_acquire) &&
        runtime->metal_backend_selected.load(std::memory_order_acquire) &&
        whisper_model_n_vocab(runtime->context) > 0;
}

extern "C" bool tw_whisper_request_cancel(tw_whisper_runtime * runtime) {
    return !runtime->cancelled.exchange(true, std::memory_order_acq_rel);
}

extern "C" void tw_whisper_begin_inference(tw_whisper_runtime * runtime) {
    runtime->cancelled.store(false, std::memory_order_release);
}

extern "C" int tw_whisper_transcribe(
    tw_whisper_runtime * runtime,
    uint8_t language,
    const char * prompt,
    const float * samples,
    size_t sample_count,
    const char ** text,
    size_t * text_len) {
    const char * language_name = language == 1 ? "en" : language == 2 ? "sv" : language == 3 ? "auto" : nullptr;
    if (language_name == nullptr || sample_count == 0 || sample_count > static_cast<size_t>(INT32_MAX)) return 2;

    const int status = whisper_full(runtime->context, parameters(runtime, language_name, prompt), samples,
                                    static_cast<int>(sample_count));
    if (status != 0) return runtime->cancelled.load(std::memory_order_acquire) ? 3 : 1;

    runtime->transcript.clear();
    for (int index = 0; index < whisper_full_n_segments(runtime->context); ++index) {
        runtime->transcript += whisper_full_get_segment_text(runtime->context, index);
    }
    const size_t first = runtime->transcript.find_first_not_of(" \t\r\n");
    const size_t last = runtime->transcript.find_last_not_of(" \t\r\n");
    if (first == std::string::npos) runtime->transcript.clear();
    else runtime->transcript = runtime->transcript.substr(first, last - first + 1);
    *text = runtime->transcript.data();
    *text_len = runtime->transcript.size();
    return 0;
}
