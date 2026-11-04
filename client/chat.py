#!/usr/bin/env python3
"""The client view of the inference platform, as a program.

Sends a standard OpenAI-style chat completion to the fleet gateway with
one model name, ml-team/chat. The client carries no API key, no provider
SDK, and no knowledge of what serves it — the response's "model" field is
the only trace of whether Qwen on the fleet or Claude answered.

Stdlib only, so it runs anywhere:

    python3 chat.py "What is the capital of France?"
    python3 chat.py --who                 # ask the model to identify itself
    python3 chat.py --url http://localhost:8081 --model ml-team/qwen-cpu "hi"
"""

import argparse
import json
import sys
import urllib.error
import urllib.request

WHO_PROMPT = "In one short sentence: which model are you and who made you?"


def main() -> int:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    p.add_argument("prompt", nargs="?", default="Say hello in one short sentence.")
    p.add_argument("--url", default="http://localhost:8080", help="gateway base URL")
    p.add_argument("--model", default="ml-team/chat", help="namespace/modelservicename")
    p.add_argument("--max-tokens", type=int, default=120)
    p.add_argument("--who", action="store_true", help=f'shortcut for: "{WHO_PROMPT}"')
    args = p.parse_args()

    body = {
        "model": args.model,
        "messages": [{"role": "user", "content": WHO_PROMPT if args.who else args.prompt}],
        "max_tokens": args.max_tokens,
    }
    req = urllib.request.Request(
        args.url.rstrip("/") + "/v1/chat/completions",
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json"},
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as resp:
            r = json.load(resp)
    except urllib.error.HTTPError as e:
        print(f"HTTP {e.code}: {e.read().decode(errors='replace')}", file=sys.stderr)
        return 1
    except OSError as e:
        print(f"cannot reach {args.url} — is gateway-tunnel.sh running? ({e})", file=sys.stderr)
        return 1

    print("asked for :", args.model)
    print("served by :", r.get("model", "?"))
    print("answer    :", r["choices"][0]["message"]["content"].strip())
    return 0


if __name__ == "__main__":
    sys.exit(main())
