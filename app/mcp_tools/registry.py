from mcp.server.mcpserver import MCPServer

mcp_server = MCPServer(
    name="personal-ai-mcp",
    title="Personal AI MCP",
    description=(
        "Central MCP server for a cross-device personal AI: memory, tasks, "
        "calendar, web, files, and device context. Callable by Alexa+ and by "
        "autonomous agents (e.g. Nemotron)."
    ),
    version="0.1.0",
)
