#!/usr/bin/env python3
"""
LM Studio v1 REST API - Comprehensive Examples

This script demonstrates ALL LM Studio v1 REST API endpoints:
- POST /api/v1/chat - Stateful chat with MCP support
- GET /api/v1/models - List loaded models
- POST /api/v1/models/load - Load model with configuration
- POST /api/v1/models/unload - Unload model by instance_id
- POST /api/v1/models/download - Download models
- GET /api/v1/models/download/status/:job_id - Download status

Features:
- 256K context windows for Qwen3.5 models
- MCP (Model Context Protocol) integration
- Stateful chats with response_id
- Reasoning modes
- Dynamic context length per request
"""

import asyncio
import sys
import os
from pathlib import Path

# Add gateway module to path
sys.path.insert(0, str(Path(__file__).parent.parent / "modules/services/ai-inference/ai_inference_gateway"))

from lmstudio_client import LMStudioClient
from datetime import datetime

# Configuration
LM_STUDIO_URL = "http://127.0.0.1:1234"
API_KEY = Path("/run/agenix/lm-studio-api-key").read_text().strip() if Path("/run/agenix/lm-studio-api-key").exists() else None


async def example_basic_chat():
    """Example 1: Basic chat with 256K context window."""
    print("\n" + "="*60)
    print("EXAMPLE 1: Basic Chat with 256K Context")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    response = await client.chat(
        model="magnum-opus-35b-a3b-i1",
        input="What is the capital of France? Answer briefly.",
        temperature=0.0,
        context_length=262144,  # Request full 256K context!
    )

    print(f"Model: {response.model_instance_id}")
    print(f"Response: {response.output[0].content if response.output else 'No output'}")
    print(f"Tokens/sec: {response.stats.tokens_per_second:.2f}")
    print(f"Input tokens: {response.stats.input_tokens}")
    print(f"Output tokens: {response.stats.total_output_tokens}")


async def example_stateful_chat():
    """Example 2: Stateful chat with conversation history."""
    print("\n" + "="*60)
    print("EXAMPLE 2: Stateful Chat with Response ID")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # First message
    response1 = await client.chat(
        model="qwen/qwen3.5-9b",
        input="My favorite color is blue.",
        store=True,  # Important: store to get response_id
    )

    response_id = response1.response_id
    print(f"First response ID: {response_id}")

    # Continue conversation
    response2 = await client.chat(
        model="qwen/qwen3.5-9b",
        input="What's my favorite color?",
        previous_response_id=response_id,  # Continue from here
    )

    print(f"Follow-up response: {response2.output[0].content if response2.output else 'No output'}")


async def example_mcp_integration():
    """Example 3: Chat with MCP (Model Context Protocol) integration."""
    print("\n" + "="*60)
    print("EXAMPLE 3: MCP Integration - Web Search + Browser")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # Use ephemeral MCP server for web search
    response = await client.chat(
        model="magnum-opus-35b-a3b-i1",
        input="What are the latest AI developments in 2026?",
        integrations=[
            {
                "type": "ephemeral_mcp",
                "server_label": "web-search",
                "server_url": "https://api.example.com/mcp/search",
                "allowed_tools": ["search_web"],
            }
        ],
        context_length=8000,  # Recommended for MCP usage
        temperature=0.0,
    )

    print(f"Model: {response.model_instance_id}")

    # Parse output
    for item in response.output:
        if item.type == "message":
            print(f"Message: {item.content[:200]}...")
        elif item.type == "tool_call":
            print(f"Tool call: {item.tool}")
            print(f"Arguments: {item.arguments}")
        elif item.type == "reasoning":
            print(f"Reasoning: {item.content[:200]}...")


async def example_reasoning_modes():
    """Example 4: Reasoning modes (off/low/medium/high/on)."""
    print("\n" + "="*60)
    print("EXAMPLE 4: Reasoning Modes")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    reasoning_levels = ["off", "low", "medium", "high", "on"]

    for level in reasoning_levels:
        print(f"\n--- Reasoning: {level} ---")
        try:
            response = await client.chat(
                model="magnum-opus-35b-a3b-i1",
                input="What is 15 + 27? Think step by step.",
                reasoning=level,
                max_output_tokens=200,
            )

            reasoning_tokens = response.stats.reasoning_output_tokens
            content = response.output[0].content if response.output else ""

            print(f"Reasoning tokens: {reasoning_tokens}")
            print(f"Answer: {content[:150]}...")
        except Exception as e:
            print(f"Error: {e}")


async def example_list_models():
    """Example 5: List all loaded models."""
    print("\n" + "="*60)
    print("EXAMPLE 5: List Loaded Models")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    models = await client.list_models()

    print(f"Total loaded models: {len(models.models)}\n")

    for model in models.models:
        print(f"ID: {model.id}")
        print(f"Instance: {model.instance_id}")
        print(f"Loaded at: {model.loaded_at}")
        print()


async def example_load_model():
    """Example 6: Load model with configuration (256K context)."""
    print("\n" + "="*60)
    print("EXAMPLE 6: Load Model with Configuration")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # Load model with 256K context window on specific GPU
    response = await client.load_model(
        model="qwen/qwen3.5-9b",
        context_length=262144,  # 256K context window!
        gpu_split="gpu_1",  # Load on second GPU
        quantization="Q4_K_M",
    )

    print(f"Model loaded successfully!")
    print(f"Instance ID: {response.instance_id}")
    print(f"Model: {response.model}")
    print(f"Loaded at: {response.loaded_at}")


async def example_unload_model():
    """Example 7: Unload model to free GPU memory."""
    print("\n" + "="*60)
    print("EXAMPLE 7: Unload Model")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # First, list loaded models
    models = await client.list_models()

    if models.models:
        # Unload the first model
        instance_id = models.models[0].instance_id

        response = await client.unload_model(instance_id=instance_id)

        print(f"Model unloaded: {response.instance_id}")
    else:
        print("No models loaded to unload.")


async def example_download_model():
    """Example 8: Download model with progress tracking."""
    print("\n" + "="*60)
    print("EXAMPLE 8: Download Model with Progress")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # Start download
    download_response = await client.download_model(
        model="qwen3.5-2b",
        quantization="Q4_K_M",
    )

    if download_response.status == "already_downloaded":
        print("Model already downloaded!")
        return

    job_id = download_response.job_id
    print(f"Download started: {job_id}")
    print(f"Status: {download_response.status}")
    print(f"Total size: {download_response.total_size_bytes / (1024**3):.2f} GB")

    # Poll for progress
    while True:
        status = await client.get_download_status(job_id)

        if status.status == "downloading":
            percent = (status.downloaded_bytes / status.total_size_bytes * 100)
            speed_mb = status.bytes_per_second / (1024**2)
            print(f"Progress: {percent:.1f}% @ {speed_mb:.1f} MB/s")
            await asyncio.sleep(2)

        elif status.status == "completed":
            print("Download completed!")
            break

        elif status.status == "failed":
            print("Download failed!")
            break

        await asyncio.sleep(1)


async def example_multimodal():
    """Example 9: Multimodal chat with images."""
    print("\n" + "="*60)
    print("EXAMPLE 9: Multimodal Chat (Text + Images)")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    # Example with image input (base64-encoded)
    # In practice, you'd encode your image: base64.b64encode(image_data).decode()
    response = await client.chat(
        model="qwen/qwen3.5-9b",
        input=[
            {
                "type": "message",
                "content": "Describe this image in detail.",
            },
            {
                "type": "image",
                "data_url": "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg==",
            }
        ],
    )

    print(f"Response: {response.output[0].content if response.output else 'No output'}")


async def example_all_parameters():
    """Example 10: All chat parameters."""
    print("\n" + "="*60)
    print("EXAMPLE 10: All Chat Parameters")
    print("="*60)

    client = LMStudioClient(base_url=LM_STUDIO_URL, api_token=API_KEY)

    response = await client.chat(
        model="magnum-opus-35b-a3b-i1",
        input="Write a haiku about AI.",
        # Sampling parameters
        temperature=0.8,
        top_p=0.95,
        top_k=40,
        min_p=0.05,
        repeat_penalty=1.1,
        # Output control
        max_output_tokens=100,
        # Context
        context_length=262144,  # 256K!
        # Reasoning
        reasoning="medium",
        # System prompt
        system_prompt="You are a poetic AI assistant.",
    )

    print(f"Response: {response.output[0].content if response.output else 'No output'}")
    print(f"\nStats:")
    print(f"  Input tokens: {response.stats.input_tokens}")
    print(f"  Output tokens: {response.stats.total_output_tokens}")
    print(f"  Reasoning tokens: {response.stats.reasoning_output_tokens}")
    print(f"  Tokens/sec: {response.stats.tokens_per_second:.2f}")
    print(f"  Time to first token: {response.stats.time_to_first_token_seconds:.3f}s")


async def main():
    """Run all examples."""
    print("="*60)
    print("LM Studio v1 REST API - Comprehensive Examples")
    print("="*60)
    print(f"Server: {LM_STUDIO_URL}")
    print(f"Auth: {'Enabled' if API_KEY else 'Disabled'}")

    examples = [
        ("Basic Chat", example_basic_chat),
        ("Stateful Chat", example_stateful_chat),
        ("MCP Integration", example_mcp_integration),
        ("Reasoning Modes", example_reasoning_modes),
        ("List Models", example_list_models),
        ("Load Model", example_load_model),
        ("Unload Model", example_unload_model),
        # ("Download Model", example_download_model),  # Uncomment to test download
        # ("Multimodal", example_multimodal),  # Requires vision model
        ("All Parameters", example_all_parameters),
    ]

    print(f"\nRunning {len(examples)} examples...")
    print("Note: Some examples may fail if models are not loaded.\n")

    for name, example_fn in examples:
        try:
            await example_fn()
        except Exception as e:
            print(f"\n❌ Example '{name}' failed: {e}")
            import traceback
            traceback.print_exc()

    print("\n" + "="*60)
    print("Examples completed!")
    print("="*60)


if __name__ == "__main__":
    asyncio.run(main())
