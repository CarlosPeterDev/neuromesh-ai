// Live host inference check, using the same common/chat path as Android JNI.
// Requires an actual compatible GGUF; no generated thoughts are inserted.
#include "chat.h"
#include "llama.h"
#include <iostream>
#include <stdexcept>
#include <vector>

static std::string generate(llama_model* model, const std::string& prompt) {
    auto cp = llama_context_default_params();
    cp.n_ctx = 2048; cp.n_batch = 512; cp.n_threads = 2; cp.n_threads_batch = 2;
    auto ctx = llama_init_from_model(model, cp);
    if (!ctx) throw std::runtime_error("Could not create inference context");
    const auto vocab = llama_model_get_vocab(model);
    std::vector<llama_token> tokens(prompt.size()+32);
    const int n = llama_tokenize(vocab,prompt.data(),prompt.size(),tokens.data(),tokens.size(),true,true);
    if (n <= 0 || n > 512) throw std::runtime_error("Unexpected prompt token count");
    tokens.resize(n);
    if (llama_decode(ctx,llama_batch_get_one(tokens.data(),tokens.size()))) throw std::runtime_error("Prompt decode failed");
    auto sampler = llama_sampler_init_greedy();
    std::string output;
    for(int i=0;i<384;++i) {
        auto token=llama_sampler_sample(sampler,ctx,-1);
        if(llama_vocab_is_eog(vocab,token))break;
        char piece[256];
        int count=llama_token_to_piece(vocab,token,piece,sizeof(piece),0,true);
        if(count>0)output.append(piece,count);
        if(llama_decode(ctx,llama_batch_get_one(&token,1)))throw std::runtime_error("Generation decode failed");
    }
    llama_sampler_free(sampler);llama_free(ctx);
    return output;
}
int main(int argc,char** argv) {
    if(argc!=2){std::cerr<<"Usage: verify_model_thinking model.gguf\n";return 2;}
    try {
        llama_backend_init();
        auto mp=llama_model_default_params();mp.n_gpu_layers=0;
        auto model=llama_model_load_from_file(argv[1],mp);
        if(!model)throw std::runtime_error("Model load failed");
        auto templates=common_chat_templates_init(model,"");
        if(!common_chat_templates_support_enable_thinking(templates.get()))throw std::runtime_error("Model does not support enable_thinking");
        common_chat_templates_inputs input;
        common_chat_msg message;message.role="user";message.content="What is 12 times 13? Answer briefly.";
        input.messages.push_back(message);
        std::string prompts[2],outputs[2];
        for(int mode=0;mode<2;++mode){
            input.enable_thinking=mode==1;
            input.chat_template_kwargs["enable_thinking"]=mode ? "true":"false";
            prompts[mode]=common_chat_templates_apply(templates.get(),input).prompt;
            outputs[mode]=generate(model,prompts[mode]);
            if(outputs[mode].empty())throw std::runtime_error("No model output");
        }
        if(prompts[0]==prompts[1])throw std::runtime_error("Thinking flag did not change the prompt");
        if(outputs[0].find("156")==std::string::npos || outputs[1].find("156")==std::string::npos)throw std::runtime_error("Arithmetic answer missing");
        if(outputs[1].find("</think>")==std::string::npos)throw std::runtime_error("Enabled reasoning did not terminate within the token budget");
        if(outputs[0].find("</think>")!=std::string::npos)throw std::runtime_error("Disabled mode generated a reasoning block");
        std::cout<<"PASS: same GGUF, distinct enabled/disabled prompts, nonempty inference, correct answer, enabled reasoning closes, disabled reasoning absent.\n";
        llama_model_free(model);llama_backend_free();return 0;
    } catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
