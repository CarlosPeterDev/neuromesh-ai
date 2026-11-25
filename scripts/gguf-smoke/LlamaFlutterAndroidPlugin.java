package com.neuromesh.llama_flutter_android;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Paths;
import java.util.Base64;
import java.util.Locale;

/** Calls the production JNI entry points from a clean process with synthetic input. */
public final class LlamaFlutterAndroidPlugin {
    public static final class Progress {
        public Object invoke(Object value) { return null; }
    }

    public static final class Tokens {
        public final StringBuilder text = new StringBuilder();
        long count;
        long elapsedMicros;

        public void onToken(String value, long count, long elapsedMicros) {
            require(count >= this.count && elapsedMicros >= this.elapsedMicros,
                    "decode statistics went backwards");
            this.count = count;
            this.elapsedMicros = elapsedMicros;
            text.append(value);
        }
    }

    private Tokens lastDecode;

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
        return generate(label, prompt, image, greedy, 40);
    }

    private String generate(String label, String prompt, String image, boolean greedy, int limit) {
        nativePrepareGeneration();
        final Tokens callback = new Tokens();
        nativeGenerate(prompt, image, limit, greedy ? 0.0 : 0.7, greedy ? 1.0 : 0.9,
                greedy ? 0 : 40, greedy ? 0.0 : 0.05, 1.0, greedy ? 1.0 : 1.1,
                0, 0, 64, 0, 5.0, 0.1, 42, true, callback);
        lastDecode = callback;
        final String result = callback.text.toString();
        System.out.println(label + " tokens=" + nativeCountPromptTokens(prompt) + " " + result.trim());
        System.out.println(label + " output_tokens=" + callback.count + " sample_elapsed_us=" + callback.elapsedMicros);
        return result;
    }

    private static void require(boolean condition, String message) {
        if (!condition) throw new AssertionError(message);
    }

    private void checkToolPlan(String system, String request, String expected) {
        final String prompt = "<|im_start|>system\n" + system + "<|im_end|>\n"
                + "<|im_start|>user\n" + request + "<|im_end|>\n"
                + "<|im_start|>assistant\n<think>\n\n</think>\n\n";
        final String actual = generate("tool-plan", prompt, null, true, 4).trim();
        require(expected.equals("text")
                ? !actual.equals("artwork") && !actual.equals("calc") && !actual.equals("mixed")
                : actual.equals(expected), "tool plan differs for " + request);
    }

    private void checkCompactTools(String path) throws IOException {
        for (String line : Files.readAllLines(Paths.get(path), StandardCharsets.UTF_8)) {
            final String[] fields = line.split("\t", 3);
            final String prompt = new String(Base64.getDecoder().decode(fields[2]), StandardCharsets.UTF_8);
            final String output = generate("compact-tool", prompt, null, true, Integer.parseInt(fields[1]));
            final String choice = output.split("\\R", 2)[0].trim();
            require(choice.equals(fields[0]), "compact tool expected " + fields[0] + ", got " + choice);
        }
    }

    public static void main(String[] args) throws IOException {
        System.loadLibrary("llama_jni");
        final LlamaFlutterAndroidPlugin smoke = new LlamaFlutterAndroidPlugin();
        smoke.nativeInitBackends(args[0], false);
        smoke.nativeLoadModel(args[1], 2, 1024, 0, new Progress());
        try {
            if (args.length == 3 && args[2].endsWith(".tsv")) {
                smoke.checkCompactTools(args[2]);
                System.out.println("COMPACT_TOOL_SMOKE_OK");
                return;
            }
            final String raw = "Hello, my name is";
            final String chat = "<|im_start|>user\nHi<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
            require(smoke.nativeCountPromptTokens(raw) == 5, "raw token count differs from reference");
            require(smoke.nativeCountPromptTokens(chat) == 13, "ChatML token count differs from reference");
            final String completion = smoke.generate("raw", raw, null, true);
            require(completion.startsWith(" John."), "raw completion differs from reference");
            final String greeting = smoke.generate("chat", chat, null, true);
            require(greeting.trim().equals("Hello! How can I help you today?"), "ChatML output differs from reference");
            require(smoke.lastDecode.count == 9 && smoke.lastDecode.elapsedMicros > 0,
                    "ChatML decode statistics differ from reference");
            require(smoke.generate("reused", chat, null, true).equals(greeting), "reused context altered greedy output");
            smoke.nativeClearContext();
            require(smoke.generate("reset", chat, null, true).equals(greeting), "reset context altered greedy output");
            final String sampled = smoke.generate("sampled", chat, null, false);
            require(sampled.toLowerCase(Locale.ROOT).contains("hello") ||
                    sampled.toLowerCase(Locale.ROOT).contains("hi"), "sampled greeting did not greet");
            if (args.length >= 4) {
                final String error = smoke.nativeLoadMmproj(args[2], 2);
                require(error == null, "failed to load matching vision helper: " + error);
                require(smoke.generate("helper-loaded", chat, null, true).equals(greeting), "helper changed text output");
                final String vision = "<|im_start|>user\n<__media__>\nWhat color is this image? Answer in one word.<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
                require(smoke.generate("vision", vision, args[3], true).toLowerCase(Locale.ROOT).contains("red"), "image result did not identify red");
                require(smoke.generate("after-vision", chat, null, true).equals(greeting), "image state leaked into next text turn");
            }
            if (args.length >= 5) {
                final String system = new String(Files.readAllBytes(Paths.get(args[4])), StandardCharsets.UTF_8);
                smoke.checkToolPlan(system, "Create image of a flying car", "artwork");
                smoke.checkToolPlan(system, "A flying car above Cairo", "artwork");
                smoke.checkToolPlan(system, "Could you show me what a flying car over a rainy Cairo might look like?", "artwork");
                smoke.checkToolPlan(system, "ارسم سيارة تطير فوق القاهرة ليلاً", "artwork");
                smoke.checkToolPlan(system, "Explain how a flying car would work.", "text");
                smoke.checkToolPlan(system, "Hi", "text");
                smoke.checkToolPlan(system, "What is ((84729 × 93617) + √987654321)/(137.29² + 17.83), rounded to 8 decimal places?", "calc");
                smoke.checkToolPlan(system, "Calculate \\frac{(84729\\times93617)+\\sqrt{987654321}}{137.29^2+17.83} to 8 decimal places.", "calc");
                smoke.checkToolPlan(system, "كم يساوي (84729*93617+sqrt(987654321))/(137.29^2+17.83)؟", "calc");
                smoke.checkToolPlan(system, "Write a poem about 4 + 5.", "text");
            }
            if (args.length >= 7) {
                final String system = new String(Files.readAllBytes(Paths.get(args[6])), StandardCharsets.UTF_8);
                smoke.checkToolPlan(system, "Calculate to 8 decimal places.", "8");
            }
            if (args.length >= 6) {
                final String system = new String(Files.readAllBytes(Paths.get(args[5])), StandardCharsets.UTF_8);
                smoke.checkToolPlan(system, "I need an illustration of a flying car and a list of current aerospace funding rounds.", "mixed");
                smoke.checkToolPlan(system, "Write a prompt I could give a painter to depict a flying car.", "text");
            }
            if (args.length >= 8) {
                final String system = new String(Files.readAllBytes(Paths.get(args[7])), StandardCharsets.UTF_8);
                smoke.checkToolPlan(system, "Write a prompt I could give a painter to depict a flying car.", "text");
                smoke.checkToolPlan(system, "Could you show me what a flying car over a rainy Cairo might look like?", "artwork");
            }
            if (args.length >= 9) {
                smoke.checkCompactTools(args[8]);
            }
        } finally {
            smoke.nativeFreeModel();
        }
        System.out.println("GGUF_INFERENCE_SMOKE_OK");
    }
}
