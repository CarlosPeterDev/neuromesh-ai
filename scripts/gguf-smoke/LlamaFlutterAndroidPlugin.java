package com.neuromesh.llama_flutter_android;

import java.util.Locale;

/** Calls the production JNI entry points from a clean process with synthetic input. */
public final class LlamaFlutterAndroidPlugin {
    public static final class Progress {
        public Object invoke(Object value) { return null; }
    }

    public static final class Tokens {
        public final StringBuilder text = new StringBuilder();
        public Object invoke(Object value) {
            text.append((String) value);
            return null;
        }
    }

    private native boolean nativeInitBackends(String directory, boolean allowGpu);
    private native void nativeLoadModel(String path, long threads, long context, long gpuLayers, Progress progress);
    private native String nativeLoadMmproj(String path, long threads);
    private native void nativePrepareGeneration();
    private native int nativeCountPromptTokens(String prompt);
    private native void nativeClearContext();
    private native void nativeFreeModel();
    private native void nativeGenerate(
            String prompt, String image, long limit, double temperature, double topP,
            long topK, double minP, double typicalP, double repeatPenalty,
            double frequencyPenalty, double presencePenalty, long repeatLastN,
            long mirostat, double mirostatTau, double mirostatEta, long seed,
            boolean penalizeNewline, Tokens callback);

    private String generate(String label, String prompt, String image, boolean greedy) {
        nativePrepareGeneration();
        final Tokens callback = new Tokens();
        nativeGenerate(prompt, image, 40, greedy ? 0.0 : 0.7, greedy ? 1.0 : 0.9,
                greedy ? 0 : 40, greedy ? 0.0 : 0.05, 1.0, greedy ? 1.0 : 1.1,
                0, 0, 64, 0, 5.0, 0.1, 42, true, callback);
        final String result = callback.text.toString();
        System.out.println(label + " tokens=" + nativeCountPromptTokens(prompt) + " " + result.trim());
        return result;
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    public static void main(String[] args) {
        System.loadLibrary("llama_jni");
        final LlamaFlutterAndroidPlugin smoke = new LlamaFlutterAndroidPlugin();
        smoke.nativeInitBackends(args[0], false);
        smoke.nativeLoadModel(args[1], 2, 1024, 0, new Progress());
        try {
            final String raw = "Hello, my name is";
            final String chat = "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
            require(smoke.nativeCountPromptTokens(raw) == 5, "raw token count differs from reference");
            require(smoke.nativeCountPromptTokens(chat) == 13, "ChatML token count differs from reference");
            final String completion = smoke.generate("raw", raw, null, true);
            require(completion.startsWith(" John."), "raw completion differs from reference");
            final String greeting = smoke.generate("chat", chat, null, true);
            require(greeting.trim().equals("Hello! How can I help you today?"), "ChatML output differs from reference");
            require(smoke.generate("reused", chat, null, true).equals(greeting), "reused context altered greedy output");
            smoke.nativeClearContext();
            require(smoke.generate("reset", chat, null, true).equals(greeting), "reset context altered greedy output");
            final String sampled = smoke.generate("sampled", chat, null, false);
            require(sampled.toLowerCase(Locale.ROOT).contains("hello") ||
                    sampled.toLowerCase(Locale.ROOT).contains("hi"), "sampled greeting did not greet");
            if (args.length == 4) {
                final String error = smoke.nativeLoadMmproj(args[2], 2);
                require(error == null, "failed to load matching vision helper: " + error);
                require(smoke.generate("helper-loaded", chat, null, true).equals(greeting), "helper changed text output");
                final String vision = "<|im_start|>user\n<__media__>\nWhat color is this image? Answer in one word.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
                require(smoke.generate("vision", vision, args[3], true).toLowerCase(Locale.ROOT).contains("red"), "image result did not identify red");
                require(smoke.generate("after-vision", chat, null, true).equals(greeting), "image state leaked into next text turn");
            }
        } finally {
            smoke.nativeFreeModel();
        }
        System.out.println("GGUF_INFERENCE_SMOKE_OK");
    }
}
