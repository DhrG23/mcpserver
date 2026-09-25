# Ollama MCP Agent

This is a separate client. It does not modify or run the MCP server code.
It connects to the MCP server, gives its tools to Ollama, executes the tool
calls selected by `qwen3.5:2b`, and loops until Ollama returns a normal answer.

## Arch Linux setup

From the repository root on the Arch machine:

```bash
python -m venv .venv-agent
source .venv-agent/bin/activate
python -m pip install -r agent/requirements.txt
ollama pull qwen3.5:2b
cp agent/agent.env.example agent/agent.env
```

Edit `agent/agent.env` with the MCP server address and token. For the local
Caddy configuration, use the LAN address of the machine hosting the MCP server:

```dotenv
MCP_URL=https://<mcp-host-lan-ip>:8443/mcp
OLLAMA_BASE_URL=http://127.0.0.1:11434
OLLAMA_MODEL=qwen3.5:2b
OLLAMA_TOKEN=<same value as OLLAMA_TOKEN in .env>
```

The agent loads `agent/agent.env` automatically. Do not commit that file.

If Caddy's local CA is not trusted by this Python environment, use
`MCP_VERIFY_TLS=false` only on a trusted LAN while diagnosing certificates.
Do not use that setting on an untrusted network.

## Verify, then run

First verify the MCP connection and tool discovery without asking the model to
generate anything:

```bash
python -m agent.main --check
```

Then run one request:

```bash
python -m agent.main --once 'What tasks are open?'
```

Or use the interactive loop:

```bash
python -m agent.main
```

The default Ollama API port is `11434`. Set `OLLAMA_BASE_URL` to a different
URL, such as `http://127.0.0.1:11433`, only if Ollama is actually configured
there. `8443` belongs to the MCP HTTPS endpoint, not Ollama.