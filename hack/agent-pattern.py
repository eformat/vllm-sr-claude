from langgraph.graph import StateGraph, END
from claude_code_sdk import query, ClaudeCodeOptions

async def run_sdk_agent(prompt: str, tools: list, model: str) -> dict:
    """Wrapper to run Claude Agent SDK and return structured output"""
    options = ClaudeCodeOptions(
        model=model,
        allowed_tools=tools,
        permission_mode="bypassPermissions"
    )

    output = ""
    async for message in query(prompt=prompt, options=options):
        if message.type == 'result' and message.subtype == 'success':
            output = message.result

    return {"success": True, "output": output}


async def research_node(state: WorkflowState) -> dict:
    """LangGraph node powered by Claude Agent SDK"""
    result = await run_sdk_agent(
        prompt=f"Research the following topic: {state['user_input']}",
        tools=["WebSearch", "WebFetch"],
        model="claude-sonnet-4"
    )

    return {
        "research_output": result["output"],
        "current_step": "research_complete"
    }
