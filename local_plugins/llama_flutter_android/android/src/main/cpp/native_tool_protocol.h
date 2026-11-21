#pragma once
#include "llama.cpp/common/chat.h"
#include <stdexcept>
#include <utility>

// Transport-only normalization. Decisions and argument validation remain with
// the model and AgentService; no request text is inspected for tool intent.
inline std::vector<common_chat_msg> neuromesh_native_messages(
        const std::vector<std::pair<std::string,std::string>>& history) {
    std::vector<common_chat_msg> messages;
    bool awaitingResults=false;
    for (const auto& entry : history) {
        const auto& role=entry.first; const auto& text=entry.second;
        if (role=="assistant_tool" && text.rfind("<tool_call>",0)==0) {
            const auto end=text.rfind("</tool_call>");
            if(end==std::string::npos)throw std::runtime_error("Malformed canonical tool history");
            auto data=common_json::parse(text.substr(11,end-11));
            auto calls=data.contains("calls") ? data.at("calls") : common_json::array({data});
            common_chat_msg msg;msg.role="assistant";
            for(const auto& call:calls) {
                common_chat_tool_call tool;
                tool.name=call.at("name").get<std::string>();
                tool.arguments=call.at("arguments").dump();
                tool.id=call.value("id",std::string());
                msg.tool_calls.push_back(tool);
            }
            messages.push_back(msg);awaitingResults=true;continue;
        }
        if(awaitingResults && role=="user" && !text.empty() && text[0]=='{') {
            auto data=common_json::parse_no_throw(text);
            if(!data.is_discarded() && data.is_object() && data.contains("untrusted") && data.at("untrusted").is_boolean() && data.at("untrusted").get<bool>() && data.contains("tool_results") && data.at("tool_results").is_array()) {
                for(const auto& result:data.at("tool_results")) {
                    common_chat_msg msg;msg.role="tool";
                    msg.tool_name=result.at("name").get<std::string>();
                    msg.tool_call_id=result.value("id",std::string());
                    msg.content=result.dump();messages.push_back(msg);
                }
                awaitingResults=false;continue;
            }
        }
        common_chat_msg msg;msg.role=role;msg.content=text;messages.push_back(msg);
    }
    return messages;
}

inline std::string neuromesh_normalize_native(const std::string& output, const common_chat_params& params) {
    common_chat_parser_params parser(params);
    if(!params.parser.empty())parser.parser.load(params.parser);
    parser.reasoning_format=COMMON_REASONING_FORMAT_AUTO;
    auto message=common_chat_parse(output,false,parser);
    std::string thought=message.reasoning_content.empty() ? "" : "<think>"+message.reasoning_content+"</think>\n";
    if(message.tool_calls.empty())return "<final_response>"+common_json::make(thought+message.content).dump()+"</final_response>";
    common_json calls=common_json::array();
    for(const auto& tool:message.tool_calls) {
        auto args=common_json::parse(tool.arguments);
        if(!args.is_object())throw std::runtime_error("Native tool arguments are not an object");
        common_json call={{"name",tool.name},{"arguments",args}};
        // Controller assigns task-scoped IDs, avoiding reused model-local IDs.
        calls.push_back(call);
    }
    return thought+"<tool_call>"+common_json({{"calls",calls}}).dump()+"</tool_call>";
}
