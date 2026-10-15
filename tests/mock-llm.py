"""Minimal OpenAI-compatible LLM for the smoke test. Python standard library only.

Answers deterministically, so the test can prove that the guardrails really run:
- a self check of a user message says "Yes" (block) when the message contains BLOCK-ME;
- a self check of a bot message says "Yes" when the message contains FORBIDDEN-OUTPUT;
- any other request gets an answer; a user message containing "say forbidden" gets
  FORBIDDEN-OUTPUT as the answer, one containing "say contact" an email address.
Every request is printed as one JSON line (path, Authorization header, model).
"""

import json
import sys
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer


def answer(prompt: str) -> str:
    if "Should the user message be blocked" in prompt:
        return "Yes" if "BLOCK-ME" in prompt else "No"
    if "Should the message be blocked" in prompt:
        return "Yes" if "FORBIDDEN-OUTPUT" in prompt else "No"
    if "say forbidden" in prompt.lower():
        return "FORBIDDEN-OUTPUT"
    if "say contact" in prompt.lower():
        return "Write to jane.roe@example.com."
    return "Hello from the mock LLM."


class Handler(BaseHTTPRequestHandler):
    def _json(self, status, body):
        data = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path.rstrip("/").endswith("/models"):
            self._json(200, {"object": "list", "data": [{"id": "mock-model", "object": "model", "owned_by": "mock"}]})
        else:
            self._json(404, {"error": "not found"})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))) or b"{}")
        print(json.dumps({"path": self.path, "auth": self.headers.get("Authorization"), "model": body.get("model")}), flush=True)

        if self.path.endswith("/chat/completions"):
            prompt = "\n".join(str(m.get("content", "")) for m in body.get("messages", []))
        elif self.path.endswith("/completions"):
            prompt = str(body.get("prompt", ""))
        else:
            self._json(404, {"error": "not found"})
            return
        text = answer(prompt)
        model = body.get("model", "mock-model")
        usage = {"prompt_tokens": len(prompt.split()), "completion_tokens": len(text.split()), "total_tokens": 0}

        if body.get("stream"):
            self.send_response(200)
            self.send_header("Content-Type", "text/event-stream")
            self.end_headers()
            for word in text.split(" "):
                chunk = {"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                         "choices": [{"index": 0, "delta": {"role": "assistant", "content": word + " "}, "finish_reason": None}]}
                self.wfile.write(f"data: {json.dumps(chunk)}\n\n".encode())
            done = {"id": "mock", "object": "chat.completion.chunk", "created": int(time.time()), "model": model,
                    "choices": [{"index": 0, "delta": {}, "finish_reason": "stop"}]}
            self.wfile.write(f"data: {json.dumps(done)}\n\ndata: [DONE]\n\n".encode())
            return

        if self.path.endswith("/chat/completions"):
            choice = {"index": 0, "message": {"role": "assistant", "content": text}, "finish_reason": "stop"}
            obj = "chat.completion"
        else:
            choice = {"index": 0, "text": text, "finish_reason": "stop"}
            obj = "text_completion"
        self._json(200, {"id": "mock", "object": obj, "created": int(time.time()), "model": model,
                         "choices": [choice], "usage": usage})

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 8080
    ThreadingHTTPServer(("0.0.0.0", port), Handler).serve_forever()
