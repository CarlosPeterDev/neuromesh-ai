#include "../local_plugins/llama_flutter_android/android/src/main/cpp/native_tool_protocol.h"
#include <iostream>
int main() {
 try {
  const auto plain=common_chat_templates_init(nullptr,"{% for message in messages %}{{message['role']}}: {{message['content']}}\n{% endfor %}{% if add_generation_prompt %}assistant: {% endif %}");
  if(neuromesh_reasoning_flags(plain.get())!=0) throw std::runtime_error("Plain template advertised reasoning");
  const auto toggle=common_chat_templates_init(nullptr,"{% for message in messages %}{{message['role']}}: {{message['content']}}\n{% endfor %}{% if add_generation_prompt %}assistant: {% if enable_thinking is defined and enable_thinking %}<think>{% else %}<think></think>{% endif %}{% endif %}");
  if(neuromesh_reasoning_flags(toggle.get())!=1) throw std::runtime_error("Toggle template not detected");
  const auto always=common_chat_templates_init(nullptr,"{% for message in messages %}{{message['role']}}: {% if message['reasoning_content'] is defined and message['reasoning_content'] %}<think>{{message['reasoning_content']}}</think>{% endif %}{{message['content']}}\n{% endfor %}{% if add_generation_prompt %}assistant: <think>{% endif %}");
  if(neuromesh_reasoning_flags(always.get())!=8) throw std::runtime_error("Always-on template flag="+std::to_string(neuromesh_reasoning_flags(always.get())));
  std::cout<<"PASS: template-only capability probes distinguish plain, toggleable and always-on templates without model names.\n";
 } catch(const std::exception& e){std::cerr<<"FAIL: "<<e.what()<<"\n";return 1;}
}
